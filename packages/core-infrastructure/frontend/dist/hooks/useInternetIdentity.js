import { AuthClient, scopedKeys, } from "@icp-sdk/auth/client";
import { Actor, HttpAgent } from "@icp-sdk/core/agent";
import { AttributesIdentity } from "@icp-sdk/core/identity";
import { Principal } from "@icp-sdk/core/principal";
import { createContext, createElement, useCallback, useContext, useEffect, useMemo, useRef, useState, } from "react";
import { getCachedConfig, loadConfig } from "../config";
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
 * Single constructor for every `AuthClient` — the shared client built at
 * provider initialization and the per-login clients for the Google/SSO
 * variants (`identityProvider` and `openIdProvider` are constructor-only
 * options on `@icp-sdk/auth`, so variants need their own client).
 * Delegation storage is shared across all clients, so a variant sign-in is
 * still restored by the shared client on reload and cleared by `clear()`.
 *
 * Deliberately synchronous: the signer window must be opened inside the
 * click's user-activation frame, so no awaits are allowed between the click
 * and `signIn()`. Callers that may run before the config cache is populated
 * (provider initialization) must `await loadConfig()` first; the login path
 * reads the cache, which is populated by then.
 */
function buildAuthClient(config, loginOptions, createOptions) {
    // Every flow goes through II's authorize endpoint. The pathname is forced
    // to /authorize so origin-only II_URL overrides (e.g.
    // http://localhost:5173) open the authorize flow instead of landing on
    // II's home page.
    const identityProviderUrl = new URL((createOptions?.identityProvider ??
        DEFAULT_IDENTITY_PROVIDER ??
        "https://id.ai").toString());
    identityProviderUrl.pathname = "/authorize";
    const ssoDomain = loginOptions?.ssoDomain?.trim();
    if (ssoDomain) {
        // Direct SSO passes the workspace domain as the `sso` query param,
        // e.g. https://id.ai/authorize?sso=acme.com. II discovers the
        // workspace's OIDC provider from the domain's
        // /.well-known/ii-openid-configuration.
        identityProviderUrl.searchParams.set("sso", ssoDomain);
    }
    return new AuthClient({
        idleOptions: {
            disableDefaultIdleCallback: true,
            disableIdle: true,
            ...createOptions?.idleOptions,
        },
        derivationOrigin: config?.ii_derivation_origin,
        ...createOptions,
        // After the spread so a caller-supplied identityProvider still gets
        // the /authorize normalization applied above.
        identityProvider: identityProviderUrl,
        // SSO is driven by the query param; openIdProvider only applies to
        // the Google variant (the SDK ignores undefined).
        openIdProvider: ssoDomain ? undefined : loginOptions?.provider,
    });
}
/**
 * Pick the attribute keys to request from II for a sign-in variant. Explicit
 * keys from `withAttributes` always win; otherwise the keys are scoped to the
 * sign-in variant so the user grants access in a single step.
 */
function resolveAttributeKeys(attrs, loginOptions) {
    if (attrs.keys) {
        return attrs.keys;
    }
    const ssoDomain = loginOptions?.ssoDomain?.trim();
    if (ssoDomain) {
        return [`sso:${ssoDomain}:name`, `sso:${ssoDomain}:email`];
    }
    if (loginOptions?.provider === "google") {
        // name, email, verified_email scoped to Google, e.g.
        // `openid:https://accounts.google.com:verified_email`.
        return scopedKeys({ openIdProvider: "google" });
    }
    return DEFAULT_ATTRIBUTE_KEYS;
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
        // so checking the default client covers Google and SSO sessions too.
        if (authClient.isAuthenticated()) {
            setErrorMessage("User is already authenticated");
            return;
        }
        if (loginOptions?.ssoDomain !== undefined &&
            !loginOptions.ssoDomain.trim()) {
            setErrorMessage('ssoDomain must be a non-empty domain such as "acme.com"');
            return;
        }
        const options = {
            maxTimeToLive: ONE_HOUR_IN_NANOSECONDS * BigInt(24 * 30), // 30 days
        };
        setStatus("logging-in");
        const attrs = withAttributesRef.current;
        const startSignIn = (client) => {
            if (attrs !== false) {
                // Fire nonce fetch, signIn popup, and requestAttributes all in parallel.
                // client.requestAttributes accepts Promise<Uint8Array> for nonce,
                // so the II window opens immediately while the canister round-trip completes.
                const noncePromise = createIIAttributesActor().then((actor) => actor._internet_identity_sign_in_start());
                const signInPromise = client.signIn(options);
                const attributesPromise = client.requestAttributes({
                    keys: resolveAttributeKeys(attrs, loginOptions),
                    nonce: noncePromise,
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
                });
            }
            else {
                void client
                    .signIn(options)
                    .then(async (plainIdentity) => {
                    const actor = await createIIAttributesActor(plainIdentity);
                    await actor._initialize_access_control();
                    handleLoginSuccess(client);
                })
                    .catch((unknownError) => {
                    handleLoginError(unknownError instanceof Error
                        ? unknownError.message
                        : undefined);
                });
            }
        };
        const needsVariantClient = Boolean(loginOptions?.ssoDomain?.trim() || loginOptions?.provider);
        if (needsVariantClient) {
            // Constructed synchronously so signIn() opens the signer window
            // inside the click's user-activation frame — the signer rejects
            // windows opened outside a click handler.
            try {
                startSignIn(buildAuthClient(getCachedConfig(), loginOptions ?? {}, createOptionsRef.current));
            }
            catch (unknownError) {
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
                    const config = await loadConfig();
                    if (cancelled)
                        return;
                    existingClient = buildAuthClient(config, undefined, createOptions);
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