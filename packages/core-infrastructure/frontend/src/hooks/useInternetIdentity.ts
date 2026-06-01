import {
	AuthClient,
	type AuthClientCreateOptions,
	type AuthClientSignInOptions,
} from "@icp-sdk/auth/client";
import { Actor, HttpAgent, type Identity } from "@icp-sdk/core/agent";
import type { IDL } from "@icp-sdk/core/candid";
import { AttributesIdentity } from "@icp-sdk/core/identity";
import { Principal } from "@icp-sdk/core/principal";
import {
	createContext,
	createElement,
	type PropsWithChildren,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { loadConfig } from "../config";

export type Status =
	| "initializing"
	| "idle"
	| "logging-in"
	| "success"
	| "loginError";

export type InternetIdentityContext = {
	/** The identity is available after successfully loading the identity from local storage
	 * or completing the login process. */
	identity?: Identity;

	/** Connect to Internet Identity to login the user. */
	login: () => void;

	/** Clears the identity from the state and local storage. Effectively "logs the user out". */
	clear: () => void;

	/** The loginStatus of the login process. Note: The login loginStatus is not affected when a stored
	 * identity is loaded on mount. */
	loginStatus: Status;

	/** `loginStatus === "initializing"` */
	isInitializing: boolean;

	/** `loginStatus === "idle"` */
	isLoginIdle: boolean;

	/** `loginStatus === "logging-in"` */
	isLoggingIn: boolean;

	/** `loginStatus === "success"` — true only immediately after an interactive login via the
	 * Internet Identity popup. NOT true when a stored identity is restored on page reload.
	 * For gating authenticated vs. unauthenticated UI, use {@link isAuthenticated} instead. */
	isLoginSuccess: boolean;

	/** `loginStatus === "loginError"` */
	isLoginError: boolean;

	/** `true` when the user holds a valid, non-anonymous identity (i.e. `!!identity`).
	 * Covers both interactive login AND restored sessions on page reload.
	 * Use this for conditional rendering of authenticated UI. */
	isAuthenticated: boolean;

	loginError?: Error;
};

/**
 * Provider-level configuration for requesting signed II attribute bundles on sign-in.
 * Enabled by default on `InternetIdentityProvider`; `login()` runs the full
 * nonce → signIn → requestAttributes → finish flow unless `withAttributes={false}`.
 */
export type AttributeProviderConfig = {
	/** Attribute keys to request from II. Defaults to `['verified_email']`. */
	keys?: string[];
};

// Inline Candid IDL for the two methods injected by the IdentityAttributes mixin.
// Defined once at module level so it is not recreated on every render.
const iiAttributesIDL: IDL.InterfaceFactory = ({ IDL: I }) =>
	I.Service({
		_internet_identity_sign_in_start: I.Func([], [I.Vec(I.Nat8)], []),
		_internet_identity_sign_in_finish: I.Func(
			[],
			[I.Variant({ ok: I.Null, err: I.Record({}) })],
			[],
		),
		_initialize_access_control: I.Func([], [], []),
	});

type IIAttributesActor = {
	_internet_identity_sign_in_start: () => Promise<Uint8Array>;
	_internet_identity_sign_in_finish: () => Promise<
		{ ok: null } | { err: Record<string, unknown> }
	>;
	_initialize_access_control: () => Promise<void>;
};

const II_MAINNET_CANISTER_ID = "rdmx6-jaaaa-aaaaa-aaadq-cai";
const II_SIGNER_CANISTER_ID =
	process.env.II_CANISTER_ID ?? II_MAINNET_CANISTER_ID;

const ONE_HOUR_IN_NANOSECONDS = BigInt(3_600_000_000_000);
const DEFAULT_IDENTITY_PROVIDER = process.env.II_URL;

const DEFAULT_ATTRIBUTE_KEYS = ["verified_email"];

type ProviderValue = InternetIdentityContext;
const InternetIdentityReactContext = createContext<ProviderValue | undefined>(
	undefined,
);

/**
 * Create the auth client with default options or options provided by the user.
 */
async function createAuthClient(
	createOptions?: AuthClientCreateOptions,
): Promise<AuthClient> {
	const config = await loadConfig();
	const options: AuthClientCreateOptions = {
		idleOptions: {
			disableDefaultIdleCallback: true,
			disableIdle: true,
			...createOptions?.idleOptions,
		},
		identityProvider: DEFAULT_IDENTITY_PROVIDER,
		derivationOrigin: config.ii_derivation_origin,
		...createOptions,
	};
	return new AuthClient(options);
}

/**
 * Create an inline actor for the two IdentityAttributes mixin methods.
 * Uses the same `backend_canister_id` and `backend_host` as the rest of the app.
 */
async function createIIAttributesActor(
	identity?: Identity,
): Promise<IIAttributesActor> {
	const config = await loadConfig();
	const agent = new HttpAgent({
		host: config.backend_host,
		identity,
	});
	if (config.backend_host?.includes("localhost")) {
		await agent.fetchRootKey().catch(() => {
			/* best-effort */
		});
	}
	return Actor.createActor<IIAttributesActor>(iiAttributesIDL, {
		agent,
		canisterId: config.backend_canister_id,
	});
}

/**
 * Helper function to set loginError state.
 */
function assertProviderPresent(
	context: ProviderValue | undefined,
): asserts context is ProviderValue {
	if (!context) {
		throw new Error(
			"InternetIdentityProvider is not present. Wrap your component tree with it.",
		);
	}
}

/**
 * Hook to access the internet identity as well as loginStatus along with
 * login and clear functions.
 */
export const useInternetIdentity = (): InternetIdentityContext => {
	const context = useContext(InternetIdentityReactContext);
	assertProviderPresent(context);
	return context;
};

/**
 * The InternetIdentityProvider component makes the saved identity available
 * after page reloads. It also allows you to configure default options
 * for AuthClient and login.
 *
 *
 * @example
 * ```tsx
 * <InternetIdentityProvider>
 *   <App />
 * </InternetIdentityProvider>
 * ```
 *
 * Attribute verification is enabled by default (`verified_email` from Internet Identity).
 * Pass `withAttributes={false}` to use plain sign-in only, or override keys explicitly:
 * ```tsx
 * <InternetIdentityProvider withAttributes={{ keys: ['email', 'verified_email'] }}>
 *   <App />
 * </InternetIdentityProvider>
 * ```
 */
export function InternetIdentityProvider({
	children,
	createOptions,
	withAttributes = {},
}: PropsWithChildren<{
	/** The child components that the InternetIdentityProvider will wrap. This allows any child
	 * component to access the authentication context provided by the InternetIdentityProvider. */
	children: ReactNode;

	/** Options for creating the {@link AuthClient}. See AuthClient documentation for list of options
	 *
	 * defaults to disabling the AuthClient idle handling (clearing identities
	 * from store and reloading the window on identity expiry). If that behaviour is preferred, set these settings:
	 *
	 * ```
	 * const options = {
	 *   idleOptions: {
	 *     disableDefaultIdleCallback: false,
	 *     disableIdle: false,
	 *   },
	 * }
	 * ```
	 */
	createOptions?: AuthClientCreateOptions;

	/**
	 * Controls the II attribute-bundle flow on login. Defaults to `{}` (enabled, requesting
	 * `verified_email`). Pass `false` for plain sign-in only. When enabled, nonce fetch,
	 * signIn, requestAttributes, and `_internet_identity_sign_in_finish` are handled internally.
	 */
	withAttributes?: AttributeProviderConfig | false;
}>) {
	const [authClient, setAuthClient] = useState<AuthClient | undefined>(
		undefined,
	);
	const [identity, setIdentity] = useState<Identity | undefined>(undefined);
	const [loginStatus, setStatus] = useState<Status>("initializing");
	const [loginError, setError] = useState<Error | undefined>(undefined);

	// Keep withAttributes in a ref so the login callback stays stable
	// while still reading the latest prop value on each invocation.
	const withAttributesRef = useRef(withAttributes);
	withAttributesRef.current = withAttributes;

	const setErrorMessage = useCallback((message: string) => {
		setStatus("loginError");
		setError(new Error(message));
	}, []);

	const handleLoginSuccess = useCallback(
		async (client: AuthClient) => {
			const latestIdentity = await client.getIdentity();
			if (!latestIdentity) {
				setErrorMessage("Identity not found after successful login");
				return;
			}
			setIdentity(latestIdentity);
			setStatus("success");
		},
		[setErrorMessage],
	);

	const handleLoginError = useCallback(
		(maybeError?: string) => {
			setErrorMessage(maybeError ?? "Login failed");
		},
		[setErrorMessage],
	);

	const login = useCallback(() => {
		if (!authClient) {
			setErrorMessage(
				"AuthClient is not initialized yet, make sure to call `login` on user interaction e.g. click.",
			);
			return;
		}

		if (authClient.isAuthenticated()) {
			setErrorMessage("User is already authenticated");
			return;
		}

		const options: AuthClientSignInOptions = {
			maxTimeToLive: ONE_HOUR_IN_NANOSECONDS * BigInt(24 * 30), // 30 days
		};

		setStatus("logging-in");

		const attrs = withAttributesRef.current;

		if (attrs !== false) {
			// Fire nonce fetch, signIn popup, and requestAttributes all in parallel.
			// authClient.requestAttributes accepts Promise<Uint8Array> for nonce,
			// so the II window opens immediately while the canister round-trip completes.
			const noncePromise = createIIAttributesActor().then((actor) =>
				actor._internet_identity_sign_in_start(),
			);
			const signInPromise = authClient.signIn(options);
			const attributesPromise = authClient.requestAttributes({
				keys: attrs.keys ?? DEFAULT_ATTRIBUTE_KEYS,
				nonce: noncePromise,
			});

			void Promise.all([signInPromise, attributesPromise])
				.then(async ([plainIdentity, { data, signature }]) => {
					const actor = await createIIAttributesActor(plainIdentity);
					if (!data || data.length === 0) {
						await handleLoginSuccess(authClient);
						await actor._initialize_access_control();
						return;
					}

					const signerCanisterId = Principal.fromText(II_SIGNER_CANISTER_ID);
					const attributedIdentity = new AttributesIdentity({
						inner: plainIdentity,
						attributes: { data, signature },
						signer: { canisterId: signerCanisterId },
					});
					const finishActor = await createIIAttributesActor(attributedIdentity);
					try {
						await finishActor._internet_identity_sign_in_finish();
					} catch (error) {
						console.error(error);
					}
					await handleLoginSuccess(authClient);
				})
				.catch((unknownError: unknown) => {
					handleLoginError(
						unknownError instanceof Error ? unknownError.message : undefined,
					);
				});
		} else {
			void authClient
				.signIn(options)
				.then(async (plainIdentity) => {
					const actor = await createIIAttributesActor(plainIdentity);
					await actor._initialize_access_control();
					handleLoginSuccess(authClient);
				})
				.catch((unknownError: unknown) => {
					handleLoginError(
						unknownError instanceof Error ? unknownError.message : undefined,
					);
				});
		}
	}, [authClient, handleLoginError, handleLoginSuccess, setErrorMessage]);

	const clear = useCallback(() => {
		if (!authClient) {
			setErrorMessage("Auth client not initialized");
			return;
		}

		void authClient
			.signOut()
			.then(() => {
				setIdentity(undefined);
				setAuthClient(undefined);
				setStatus("idle");
				setError(undefined);
			})
			.catch((unknownError: unknown) => {
				setStatus("loginError");
				setError(
					unknownError instanceof Error
						? unknownError
						: new Error("Logout failed"),
				);
			});
	}, [authClient, setErrorMessage]);

	useEffect(() => {
		let cancelled = false;
		void (async () => {
			try {
				setStatus("initializing");
				let existingClient = authClient;
				if (!existingClient) {
					existingClient = await createAuthClient(createOptions);
					if (cancelled) return;
					setAuthClient(existingClient);
				}
				if (cancelled) return;
				if (existingClient.isAuthenticated()) {
					const loadedIdentity = await existingClient.getIdentity();
					if (cancelled) return;
					setIdentity(loadedIdentity);
					setStatus("success");
				} else {
					setIdentity(undefined);
					setStatus("idle");
				}
			} catch (unknownError) {
				if (cancelled) return;
				setIdentity(undefined);
				setStatus("loginError");
				setError(
					unknownError instanceof Error
						? unknownError
						: new Error("Initialization failed"),
				);
			}
		})();
		return () => {
			cancelled = true;
		};
	}, [createOptions, authClient]);

	const value = useMemo<ProviderValue>(
		() => ({
			identity,
			login,
			clear,
			loginStatus,
			isInitializing: loginStatus === "initializing",
			isLoginIdle: loginStatus === "idle",
			isLoggingIn: loginStatus === "logging-in",
			isLoginSuccess: loginStatus === "success",
			isLoginError: loginStatus === "loginError",
			isAuthenticated: !!identity && !identity.getPrincipal().isAnonymous(),
			loginError,
		}),
		[identity, login, clear, loginStatus, loginError],
	);

	return createElement(InternetIdentityReactContext.Provider, {
		value,
		children,
	});
}
