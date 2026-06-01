import { AuthClient, } from "@icp-sdk/auth/client";
import { Actor, HttpAgent } from "@icp-sdk/core/agent";
import { AttributesIdentity } from "@icp-sdk/core/identity";
import { Principal } from "@icp-sdk/core/principal";
import { createContext, createElement, useCallback, useContext, useEffect, useMemo, useRef, useState, } from "react";
import { loadConfig } from "../config";
// Inline Candid IDL for the two methods injected by the IdentityAttributes mixin.
// Defined once at module level so it is not recreated on every render.
const iiAttributesIDL = ({ IDL: I }) => I.Service({
    _internet_identity_sign_in_start: I.Func([], [I.Vec(I.Nat8)], []),
    _internet_identity_sign_in_finish: I.Func([], [I.Variant({ ok: I.Null, err: I.Record({}) })], []),
    _initialize_access_control: I.Func([], [], []),
});
const II_MAINNET_CANISTER_ID = "rdmx6-jaaaa-aaaaa-aaadq-cai";
const II_SIGNER_CANISTER_ID = process.env.II_CANISTER_ID ?? II_MAINNET_CANISTER_ID;
const ONE_HOUR_IN_NANOSECONDS = BigInt(3_600_000_000_000);
const DEFAULT_IDENTITY_PROVIDER = process.env.II_URL;
const DEFAULT_ATTRIBUTE_KEYS = ["verified_email"];
const InternetIdentityReactContext = createContext(undefined);
/**
 * Create the auth client with default options or options provided by the user.
 */
async function createAuthClient(createOptions) {
    const config = await loadConfig();
    const options = {
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
async function createIIAttributesActor(identity) {
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
    return Actor.createActor(iiAttributesIDL, {
        agent,
        canisterId: config.backend_canister_id,
    });
}
/**
 * Helper function to set loginError state.
 */
function assertProviderPresent(context) {
    if (!context) {
        throw new Error("InternetIdentityProvider is not present. Wrap your component tree with it.");
    }
}
/**
 * Hook to access the internet identity as well as loginStatus along with
 * login and clear functions.
 */
export const useInternetIdentity = () => {
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
export function InternetIdentityProvider({ children, createOptions, withAttributes = {}, }) {
    const [authClient, setAuthClient] = useState(undefined);
    const [identity, setIdentity] = useState(undefined);
    const [loginStatus, setStatus] = useState("initializing");
    const [loginError, setError] = useState(undefined);
    // Keep withAttributes in a ref so the login callback stays stable
    // while still reading the latest prop value on each invocation.
    const withAttributesRef = useRef(withAttributes);
    withAttributesRef.current = withAttributes;
    const setErrorMessage = useCallback((message) => {
        setStatus("loginError");
        setError(new Error(message));
    }, []);
    const handleLoginSuccess = useCallback(async (client) => {
        const latestIdentity = await client.getIdentity();
        if (!latestIdentity) {
            setErrorMessage("Identity not found after successful login");
            return;
        }
        setIdentity(latestIdentity);
        setStatus("success");
    }, [setErrorMessage]);
    const handleLoginError = useCallback((maybeError) => {
        setErrorMessage(maybeError ?? "Login failed");
    }, [setErrorMessage]);
    const login = useCallback(() => {
        if (!authClient) {
            setErrorMessage("AuthClient is not initialized yet, make sure to call `login` on user interaction e.g. click.");
            return;
        }
        if (authClient.isAuthenticated()) {
            setErrorMessage("User is already authenticated");
            return;
        }
        const options = {
            maxTimeToLive: ONE_HOUR_IN_NANOSECONDS * BigInt(24 * 30), // 30 days
        };
        setStatus("logging-in");
        const attrs = withAttributesRef.current;
        if (attrs !== false) {
            // Fire nonce fetch, signIn popup, and requestAttributes all in parallel.
            // authClient.requestAttributes accepts Promise<Uint8Array> for nonce,
            // so the II window opens immediately while the canister round-trip completes.
            const noncePromise = createIIAttributesActor().then((actor) => actor._internet_identity_sign_in_start());
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
                }
                catch (error) {
                    console.error(error);
                }
                await handleLoginSuccess(authClient);
            })
                .catch((unknownError) => {
                handleLoginError(unknownError instanceof Error ? unknownError.message : undefined);
            });
        }
        else {
            void authClient
                .signIn(options)
                .then(async (plainIdentity) => {
                const actor = await createIIAttributesActor(plainIdentity);
                await actor._initialize_access_control();
                handleLoginSuccess(authClient);
            })
                .catch((unknownError) => {
                handleLoginError(unknownError instanceof Error ? unknownError.message : undefined);
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
            .catch((unknownError) => {
            setStatus("loginError");
            setError(unknownError instanceof Error
                ? unknownError
                : new Error("Logout failed"));
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
                    if (cancelled)
                        return;
                    setAuthClient(existingClient);
                }
                if (cancelled)
                    return;
                if (existingClient.isAuthenticated()) {
                    const loadedIdentity = await existingClient.getIdentity();
                    if (cancelled)
                        return;
                    setIdentity(loadedIdentity);
                    setStatus("success");
                }
                else {
                    setIdentity(undefined);
                    setStatus("idle");
                }
            }
            catch (unknownError) {
                if (cancelled)
                    return;
                setIdentity(undefined);
                setStatus("loginError");
                setError(unknownError instanceof Error
                    ? unknownError
                    : new Error("Initialization failed"));
            }
        })();
        return () => {
            cancelled = true;
        };
    }, [createOptions, authClient]);
    const value = useMemo(() => ({
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
    }), [identity, login, clear, loginStatus, loginError]);
    return createElement(InternetIdentityReactContext.Provider, {
        value,
        children,
    });
}
//# sourceMappingURL=useInternetIdentity.js.map