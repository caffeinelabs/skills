import { type AuthClientCreateOptions } from "@dfinity/auth-client";
import type { Identity } from "@icp-sdk/core/agent";
import { type PropsWithChildren, type ReactNode } from "react";
export type Status = "initializing" | "idle" | "logging-in" | "success" | "loginError";
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
 * Hook to access the internet identity as well as loginStatus along with
 * login and clear functions.
 */
export declare const useInternetIdentity: () => InternetIdentityContext;
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
export declare function InternetIdentityProvider({ children, createOptions, }: PropsWithChildren<{
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
}>): import("react").FunctionComponentElement<import("react").ProviderProps<InternetIdentityContext | undefined>>;
