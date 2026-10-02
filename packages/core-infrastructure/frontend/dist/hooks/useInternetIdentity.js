import { AuthClient, } from "@icp-sdk/auth/client";
import { Actor, HttpAgent } from "@icp-sdk/core/agent";
import { AttributesIdentity } from "@icp-sdk/core/identity";
import { Principal } from "@icp-sdk/core/principal";
import { createContext, createElement, useCallback, useContext, useEffect, useMemo, useRef, useState, } from "react";
import { getCachedConfig, loadConfig } from "../config.js";
import { II_MAINNET_CANISTER_ID, nextLoginStatus, resolveAttributeKeys, resolveIdentityProvider, } from "./internetIdentityAuth.js";
// Inline Candid IDL for the two methods injected by the IdentityAttributes mixin.
// Defined once at module level so it is not recreated on every render.
const iiAttributesIDL = ({ IDL: I }) => I.Service({
    _internet_identity_sign_in_start: I.Func([], [I.Vec(I.Nat8)], []),
    _internet_identity_sign_in_finish: I.Func([], [I.Variant({ ok: I.Null, err: I.Record({}) })], []),
    _initialize_access_control: I.Func([], [], []),
});
const II_SIGNER_CANISTER_ID = process.env.II_CANISTER_ID ?? II_MAINNET_CANISTER_ID;
const InternetIdentityReactContext = createContext(undefined);
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
function buildAuthClient(config, loginOptions, createOptions) {
    const { identityProvider: _callerIdentityProvider, openIdProvider: _openIdProvider, ssoDomain: _ssoDomain, ...rest } = {
        derivationOrigin: config?.ii_derivation_origin,
        ...createOptions,
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
    // Keep withAttributes/createOptions in refs so the login callback stays
    // stable while still reading the latest prop values on each invocation.
    const withAttributesRef = useRef(withAttributes);
    withAttributesRef.current = withAttributes;
    const createOptionsRef = useRef(createOptions);
    createOptionsRef.current = createOptions;
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
        setError(undefined);
    }, [setErrorMessage]);
    const handleLoginError = useCallback((maybeError) => {
        setErrorMessage(maybeError ?? "Login failed");
    }, [setErrorMessage]);
    const login = useCallback((loginOptions) => {
        if (!authClient) {
            setErrorMessage("AuthClient is not initialized yet, make sure to call `login` on user interaction e.g. click.");
            return;
        }
        // The authenticated flag is shared across all sign-in variants,
        // so checking the default client covers one-click and SSO sessions too.
        if (authClient.isAuthenticated()) {
            setErrorMessage("User is already authenticated");
            return;
        }
        if (loginOptions?.ssoDomain !== undefined &&
            !loginOptions.ssoDomain.trim()) {
            setErrorMessage('ssoDomain must be a non-empty domain such as "acme.com"');
            return;
        }
        setStatus("logging-in");
        const attrs = withAttributesRef.current;
        let variantClient;
        const disposeVariant = () => {
            variantClient?.dispose();
            variantClient = undefined;
        };
        const startSignIn = (client) => {
            if (attrs !== false) {
                // Fire nonce fetch, signIn popup, and requestAttributes all in parallel.
                // nonce is a callback so the II window opens immediately while the
                // canister round-trip completes (and so a redirect replay reuses the
                // same bytes).
                const signInPromise = client.signIn();
                const attributesPromise = client.requestAttributes({
                    keys: resolveAttributeKeys(attrs, loginOptions),
                    nonce: () => createIIAttributesActor().then((actor) => actor._internet_identity_sign_in_start()),
                });
                void Promise.all([signInPromise, attributesPromise])
                    .then(async ([plainIdentity, { data, signature }]) => {
                    const actor = await createIIAttributesActor(plainIdentity);
                    if (!data || data.length === 0) {
                        await handleLoginSuccess(client);
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
                    await handleLoginSuccess(client);
                })
                    .catch((unknownError) => {
                    handleLoginError(unknownError instanceof Error
                        ? unknownError.message
                        : undefined);
                })
                    .finally(disposeVariant);
            }
            else {
                void client
                    .signIn()
                    .then(async (plainIdentity) => {
                    const actor = await createIIAttributesActor(plainIdentity);
                    await actor._initialize_access_control();
                    await handleLoginSuccess(client);
                })
                    .catch((unknownError) => {
                    handleLoginError(unknownError instanceof Error
                        ? unknownError.message
                        : undefined);
                })
                    .finally(disposeVariant);
            }
        };
        const needsVariantClient = Boolean(loginOptions?.ssoDomain?.trim() || loginOptions?.provider);
        if (needsVariantClient) {
            // Constructed synchronously so signIn() opens the signer window
            // inside the click's user-activation frame — the signer rejects
            // windows opened outside a click handler.
            try {
                variantClient = buildAuthClient(getCachedConfig(), loginOptions ?? {}, createOptionsRef.current);
                startSignIn(variantClient);
            }
            catch (unknownError) {
                disposeVariant();
                handleLoginError(unknownError instanceof Error ? unknownError.message : undefined);
            }
        }
        else {
            startSignIn(authClient);
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
        let client;
        let unsubscribe;
        void (async () => {
            try {
                setStatus("initializing");
                const config = await loadConfig();
                if (cancelled)
                    return;
                client = buildAuthClient(config, undefined, createOptions);
                setAuthClient(client);
                const applyStatus = async () => {
                    if (!client || cancelled)
                        return;
                    const session = client.getStatus();
                    if (session.state === "signed-in") {
                        try {
                            const loadedIdentity = await client.getIdentity();
                            if (cancelled)
                                return;
                            setIdentity(loadedIdentity);
                            setStatus((previous) => nextLoginStatus(session.state, previous));
                            setError(undefined);
                        }
                        catch (unknownError) {
                            if (cancelled)
                                return;
                            setIdentity(undefined);
                            setStatus("loginError");
                            setError(unknownError instanceof Error
                                ? unknownError
                                : new Error("Failed to load identity"));
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
            unsubscribe?.();
            client?.dispose();
            setAuthClient(undefined);
        };
    }, [createOptions]);
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
        isSessionExpired: loginStatus === "expired",
        isAuthenticated: !!identity && !identity.getPrincipal().isAnonymous(),
        loginError,
    }), [identity, login, clear, loginStatus, loginError]);
    return createElement(InternetIdentityReactContext.Provider, {
        value,
        children,
    });
}
//# sourceMappingURL=useInternetIdentity.js.map