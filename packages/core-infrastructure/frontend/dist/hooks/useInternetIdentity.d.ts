import { type AuthClientCreateOptions } from "@icp-sdk/auth/client";
import { type Identity } from "@icp-sdk/core/agent";
import { type PropsWithChildren, type ReactNode } from "react";
export type Status = "initializing" | "idle" | "logging-in" | "success" | "loginError";
/**
 * Options for {@link InternetIdentityContext.login} selecting how the user signs in.
 * All variants go through Internet Identity and produce the same kind of identity;
 * they only change which screen the user sees first.
 */
export type LoginOptions = {
    /**
     * One-click Google or Microsoft sign-in: Internet Identity opens that
     * provider's OAuth flow directly instead of showing its own landing page
     * first. Apple is deliberately not offered — Internet Identity returns no
     * email or name claims for it, so the attribute callback would be empty.
     */
    provider?: "google" | "microsoft";
    /**
     * Company/workspace SSO sign-in, e.g. `login({ ssoDomain: 'acme.com' })`.
     * Internet Identity discovers the company's OpenID Connect provider from
     * `https://<ssoDomain>/.well-known/ii-openid-configuration` and signs the
     * user in against it. Takes precedence over `provider` when both are set.
     */
    ssoDomain?: string;
};
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
}>): import("react").FunctionComponentElement<import("react").ProviderProps<InternetIdentityContext | undefined>>;
