import {
	AuthClient,
	type AuthClientBaseOptions,
	type AuthClientCreateOptions,
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
import { getCachedConfig, loadConfig } from "../config.js";
import {
	type AttributeProviderConfig,
	II_MAINNET_CANISTER_ID,
	type LoginOptions,
	nextLoginStatus,
	resolveAttributeKeys,
	resolveIdentityProvider,
	type Status,
} from "./internetIdentityAuth.js";

/** AuthClient options apps may pass. `identityProvider` is platform-managed. */
export type InternetIdentityCreateOptions = Omit<
	AuthClientCreateOptions,
	"identityProvider"
>;

export type {
	AttributeProviderConfig,
	LoginOptions,
	Status,
} from "./internetIdentityAuth.js";

export type InternetIdentityContext = {
	/** The identity is available after successfully loading the identity from local storage
	 * or completing the login process. */
	identity?: Identity;

	/** Connect to Internet Identity to login the user.
	 *
	 * - `login()` — plain Internet Identity sign-in.
	 * - `login({ provider: 'google' })` — one-click Google sign-in via Internet Identity.
	 * - `login({ provider: 'microsoft' })` — one-click Microsoft sign-in via Internet Identity.
	 * - `login({ ssoDomain: 'acme.com' })` — company/workspace SSO via Internet Identity.
	 */
	login: (options?: LoginOptions) => void;

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

	/** `loginStatus === "expired"` — the session ended (idle / TTL / provider revoke),
	 * not a deliberate `clear()`. */
	isSessionExpired: boolean;

	/** `true` when the user holds a valid, non-anonymous identity (i.e. `!!identity`).
	 * Covers both interactive login AND restored sessions on page reload.
	 * Use this for conditional rendering of authenticated UI. */
	isAuthenticated: boolean;

	loginError?: Error;
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

const II_SIGNER_CANISTER_ID =
	process.env.II_CANISTER_ID ?? II_MAINNET_CANISTER_ID;

type ProviderValue = InternetIdentityContext;
const InternetIdentityReactContext = createContext<ProviderValue | undefined>(
	undefined,
);

/**
 * Single constructor for every `AuthClient` — the shared client built at
 * provider initialization and the per-login clients for the one-click and
 * SSO variants (`openIdProvider` and `ssoDomain` are constructor-only
 * options on `@icp-sdk/auth`, so variants need their own client).
 * Sign-in state lives in storage, so a variant sign-in is still restored by
 * the shared client on reload and cleared by `clear()`.
 *
 * Deliberately synchronous: the signer window must be opened inside the
 * click's user-activation frame, so no awaits are allowed between the click
 * and `signIn()`. Callers that may run before the config cache is populated
 * (provider initialization) must `await loadConfig()` first; the login path
 * reads the cache, which is populated by then.
 */
function buildAuthClient(
	config: ReturnType<typeof getCachedConfig>,
	loginOptions?: LoginOptions,
	createOptions?: InternetIdentityCreateOptions,
): AuthClient {
	const {
		identityProvider: _callerIdentityProvider,
		openIdProvider: _openIdProvider,
		ssoDomain: _ssoDomain,
		...rest
	} = {
		derivationOrigin: config?.ii_derivation_origin,
		...createOptions,
	} as AuthClientBaseOptions & {
		identityProvider?: unknown;
		openIdProvider?: unknown;
		ssoDomain?: unknown;
	};

	const identityProvider = resolveIdentityProvider({
		envUrl: process.env.II_URL,
		envCanisterId: process.env.II_CANISTER_ID,
	});
	const managed = {
		...rest,
		...(identityProvider ? { identityProvider } : {}),
	};

	const ssoDomain = loginOptions?.ssoDomain?.trim();
	if (ssoDomain) {
		return new AuthClient({ ...managed, ssoDomain });
	}
	if (loginOptions?.provider) {
		return new AuthClient({
			...managed,
			openIdProvider: loginOptions.provider,
		});
	}
	return new AuthClient(managed);
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

	/** Options for creating the {@link AuthClient}. `identityProvider` is not
	 * accepted — Caffeine sets `II_URL` and `II_CANISTER_ID`. Session bounds
	 * belong on `signIn()` (`maxTimeToIdle` / `maxTimeToLive`); the idle
	 * manager is gone in `@icp-sdk/auth` v9.
	 */
	createOptions?: InternetIdentityCreateOptions;

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

	// Keep withAttributes/createOptions in refs so the login callback stays
	// stable while still reading the latest prop values on each invocation.
	const withAttributesRef = useRef(withAttributes);
	withAttributesRef.current = withAttributes;
	const createOptionsRef = useRef(createOptions);
	createOptionsRef.current = createOptions;

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
			setError(undefined);
		},
		[setErrorMessage],
	);

	const handleLoginError = useCallback(
		(maybeError?: string) => {
			setErrorMessage(maybeError ?? "Login failed");
		},
		[setErrorMessage],
	);

	const login = useCallback(
		(loginOptions?: LoginOptions) => {
			if (!authClient) {
				setErrorMessage(
					"AuthClient is not initialized yet, make sure to call `login` on user interaction e.g. click.",
				);
				return;
			}

			// The authenticated flag is shared across all sign-in variants,
			// so checking the default client covers one-click and SSO sessions too.
			if (authClient.isAuthenticated()) {
				setErrorMessage("User is already authenticated");
				return;
			}

			if (
				loginOptions?.ssoDomain !== undefined &&
				!loginOptions.ssoDomain.trim()
			) {
				setErrorMessage(
					'ssoDomain must be a non-empty domain such as "acme.com"',
				);
				return;
			}

			setStatus("logging-in");

			const attrs = withAttributesRef.current;
			let variantClient: AuthClient | undefined;

			const disposeVariant = () => {
				variantClient?.dispose();
				variantClient = undefined;
			};

			const startSignIn = (client: AuthClient) => {
				if (attrs !== false) {
					// Fire nonce fetch, signIn popup, and requestAttributes all in parallel.
					// nonce is a callback so the II window opens immediately while the
					// canister round-trip completes (and so a redirect replay reuses the
					// same bytes).
					const signInPromise = client.signIn();
					const attributesPromise = client.requestAttributes({
						keys: resolveAttributeKeys(attrs, loginOptions),
						nonce: () =>
							createIIAttributesActor().then((actor) =>
								actor._internet_identity_sign_in_start(),
							),
					});

					void Promise.all([signInPromise, attributesPromise])
						.then(async ([plainIdentity, { data, signature }]) => {
							const actor = await createIIAttributesActor(plainIdentity);
							if (!data || data.length === 0) {
								await handleLoginSuccess(client);
								await actor._initialize_access_control();
								return;
							}

							const signerCanisterId = Principal.fromText(
								II_SIGNER_CANISTER_ID,
							);
							const attributedIdentity = new AttributesIdentity({
								inner: plainIdentity,
								attributes: { data, signature },
								signer: { canisterId: signerCanisterId },
							});
							const finishActor =
								await createIIAttributesActor(attributedIdentity);
							try {
								await finishActor._internet_identity_sign_in_finish();
							} catch (error) {
								console.error(error);
							}
							await handleLoginSuccess(client);
						})
						.catch((unknownError: unknown) => {
							handleLoginError(
								unknownError instanceof Error
									? unknownError.message
									: undefined,
							);
						})
						.finally(disposeVariant);
				} else {
					void client
						.signIn()
						.then(async (plainIdentity) => {
							const actor = await createIIAttributesActor(plainIdentity);
							await actor._initialize_access_control();
							await handleLoginSuccess(client);
						})
						.catch((unknownError: unknown) => {
							handleLoginError(
								unknownError instanceof Error
									? unknownError.message
									: undefined,
							);
						})
						.finally(disposeVariant);
				}
			};

			const needsVariantClient = Boolean(
				loginOptions?.ssoDomain?.trim() || loginOptions?.provider,
			);
			if (needsVariantClient) {
				// Constructed synchronously so signIn() opens the signer window
				// inside the click's user-activation frame — the signer rejects
				// windows opened outside a click handler.
				try {
					variantClient = buildAuthClient(
						getCachedConfig(),
						loginOptions ?? {},
						createOptionsRef.current,
					);
					startSignIn(variantClient);
				} catch (unknownError) {
					disposeVariant();
					handleLoginError(
						unknownError instanceof Error ? unknownError.message : undefined,
					);
				}
			} else {
				startSignIn(authClient);
			}
		},
		[authClient, handleLoginError, handleLoginSuccess, setErrorMessage],
	);

	const clear = useCallback(() => {
		if (!authClient) {
			setErrorMessage("Auth client not initialized");
			return;
		}

		void authClient
			.signOut()
			.then(() => {
				setIdentity(undefined);
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
		let client: AuthClient | undefined;
		let unsubscribe: (() => void) | undefined;

		void (async () => {
			try {
				setStatus("initializing");
				const config = await loadConfig();
				if (cancelled) return;
				client = buildAuthClient(config, undefined, createOptions);
				setAuthClient(client);

				const applyStatus = async () => {
					if (!client || cancelled) return;
					const session = client.getStatus();
					if (session.state === "signed-in") {
						try {
							const loadedIdentity = await client.getIdentity();
							if (cancelled) return;
							setIdentity(loadedIdentity);
							setStatus((previous) => nextLoginStatus(session.state, previous));
							setError(undefined);
						} catch (unknownError) {
							if (cancelled) return;
							setIdentity(undefined);
							setStatus("loginError");
							setError(
								unknownError instanceof Error
									? unknownError
									: new Error("Failed to load identity"),
							);
						}
						return;
					}

					setIdentity(undefined);
					setStatus((previous) => nextLoginStatus(session.state, previous));
				};

				unsubscribe = client.subscribe(() => {
					void applyStatus();
				});
				await applyStatus();
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
			unsubscribe?.();
			client?.dispose();
			setAuthClient(undefined);
		};
	}, [createOptions]);

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
			isSessionExpired: loginStatus === "expired",
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
