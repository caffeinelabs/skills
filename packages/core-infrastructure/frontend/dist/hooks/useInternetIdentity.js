import { AuthClient, } from "@dfinity/auth-client";
import { DelegationIdentity, isDelegationValid } from "@icp-sdk/core/identity";
import { createContext, createElement, useCallback, useContext, useEffect, useMemo, useState, } from "react";
import { loadConfig } from "../config";
const ONE_HOUR_IN_NANOSECONDS = BigInt(3_600_000_000_000);
const DEFAULT_IDENTITY_PROVIDER = process.env.II_URL;
const InternetIdentityReactContext = createContext(undefined);
/**
 * Create the auth client with default options or options provided by the user.
 */
async function createAuthClient(createOptions) {
    const config = await loadConfig();
    const options = {
        idleOptions: {
            // Default behaviour of this hook is not to logout and reload window on identity expiration
            disableDefaultIdleCallback: true,
            disableIdle: true,
            ...createOptions?.idleOptions,
        },
        loginOptions: {
            derivationOrigin: config.ii_derivation_origin,
        },
        ...createOptions,
    };
    const authClient = await AuthClient.create(options);
    return authClient;
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
 */
export function InternetIdentityProvider({ children, createOptions, }) {
    const [authClient, setAuthClient] = useState(undefined);
    const [identity, setIdentity] = useState(undefined);
    const [loginStatus, setStatus] = useState("initializing");
    const [loginError, setError] = useState(undefined);
    const setErrorMessage = useCallback((message) => {
        setStatus("loginError");
        setError(new Error(message));
    }, []);
    const handleLoginSuccess = useCallback(() => {
        const latestIdentity = authClient?.getIdentity();
        if (!latestIdentity) {
            setErrorMessage("Identity not found after successful login");
            return;
        }
        setIdentity(latestIdentity);
        setStatus("success");
    }, [authClient, setErrorMessage]);
    const handleLoginError = useCallback((maybeError) => {
        setErrorMessage(maybeError ?? "Login failed");
    }, [setErrorMessage]);
    const login = useCallback(() => {
        if (!authClient) {
            setErrorMessage("AuthClient is not initialized yet, make sure to call `login` on user interaction e.g. click.");
            return;
        }
        const currentIdentity = authClient.getIdentity();
        if (!currentIdentity.getPrincipal().isAnonymous() &&
            currentIdentity instanceof DelegationIdentity &&
            isDelegationValid(currentIdentity.getDelegation())) {
            setErrorMessage("User is already authenticated");
            return;
        }
        const options = {
            identityProvider: DEFAULT_IDENTITY_PROVIDER,
            onSuccess: handleLoginSuccess,
            onError: handleLoginError,
            maxTimeToLive: ONE_HOUR_IN_NANOSECONDS * BigInt(24 * 30), // 30 days
        };
        setStatus("logging-in");
        void authClient.login(options);
    }, [authClient, handleLoginError, handleLoginSuccess, setErrorMessage]);
    const clear = useCallback(() => {
        if (!authClient) {
            setErrorMessage("Auth client not initialized");
            return;
        }
        void authClient
            .logout()
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
                const isAuthenticated = await existingClient.isAuthenticated();
                if (cancelled)
                    return;
                if (isAuthenticated) {
                    const loadedIdentity = existingClient.getIdentity();
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