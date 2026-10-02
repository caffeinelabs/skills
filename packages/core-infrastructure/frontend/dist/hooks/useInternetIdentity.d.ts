import { type AuthClientCreateOptions } from "@icp-sdk/auth/client";
import { type Identity } from "@icp-sdk/core/agent";
import { type PropsWithChildren, type ReactNode } from "react";
import { type AttributeProviderConfig, type LoginOptions, type Status } from "./internetIdentityAuth.js";
/** AuthClient options apps may pass. `identityProvider` is platform-managed. */
export type InternetIdentityCreateOptions = Omit<AuthClientCreateOptions, "identityProvider">;
export type { AttributeProviderConfig, LoginOptions, Status, } from "./internetIdentityAuth.js";
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
 *
 * Attribute verification is enabled by default (`verified_email` from Internet Identity).
 * Pass `withAttributes={false}` to use plain sign-in only, or override keys explicitly:
 * ```tsx
 * <InternetIdentityProvider withAttributes={{ keys: ['email', 'verified_email'] }}>
 *   <App />
 * </InternetIdentityProvider>
 * ```
 */
export declare function InternetIdentityProvider({ children, createOptions, withAttributes, }: PropsWithChildren<{
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
}>): import("react").FunctionComponentElement<import("react").ProviderProps<InternetIdentityContext | undefined>>;
