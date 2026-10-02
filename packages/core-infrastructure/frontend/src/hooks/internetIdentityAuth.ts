import { scopedKeys } from "@icp-sdk/auth/client";

export const II_MAINNET_CANISTER_ID = "rdmx6-jaaaa-aaaaa-aaadq-cai";

export type Status =
	| "initializing"
	| "idle"
	| "logging-in"
	| "success"
	| "loginError"
	| "expired";

export type SessionState =
	| "signed-in"
	| "signed-in-elsewhere"
	| "expired"
	| "signed-out";

export type IdentityProviderConfig = {
	authorizeUrl: string;
	canisterId: string;
};

export type AttributeProviderConfig = {
	/** Attribute keys to request from II. Defaults to `['verified_email']`. */
	keys?: string[];
};

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

const DEFAULT_ATTRIBUTE_KEYS = ["verified_email"];

/**
 * II's authorize URL is used verbatim. Origin-only overrides (e.g.
 * `http://localhost:5173`) must open `/authorize`, not the II home page.
 */
export function normalizeAuthorizeUrl(value: string | URL): string {
	const url = new URL(value.toString());
	url.pathname = "/authorize";
	return url.toString();
}

/**
 * Caffeine injects `II_URL` / `II_CANISTER_ID`. Apps must not set
 * `identityProvider` — omit the AuthClient option when those env vars are
 * unset (mainnet II is the default).
 */
export function resolveIdentityProvider(options?: {
	envUrl?: string;
	envCanisterId?: string;
}): IdentityProviderConfig | undefined {
	if (!options?.envUrl) {
		return undefined;
	}
	return {
		authorizeUrl: normalizeAuthorizeUrl(options.envUrl),
		canisterId: options.envCanisterId ?? II_MAINNET_CANISTER_ID,
	};
}

/**
 * Pick the attribute keys to request from II for a sign-in variant. Explicit
 * keys from `withAttributes` always win; otherwise the keys are scoped to the
 * sign-in variant so the user grants access in a single step.
 */
export function resolveAttributeKeys(
	attrs: AttributeProviderConfig,
	loginOptions?: LoginOptions,
): string[] {
	if (attrs.keys) {
		return attrs.keys;
	}
	const ssoDomain = loginOptions?.ssoDomain?.trim();
	if (ssoDomain) {
		return [...scopedKeys({ ssoDomain })];
	}
	if (loginOptions?.provider) {
		return [...scopedKeys({ openIdProvider: loginOptions.provider })];
	}
	return DEFAULT_ATTRIBUTE_KEYS;
}

/**
 * Map a storage-backed session snapshot onto the hook's loginStatus.
 *
 * Interactive login (`logging-in`) stays in progress until the session is
 * signed-in (success) or the login path reports an error. A restored or
 * other-tab sign-in is `idle` + authenticated, not `success`.
 */
export function nextLoginStatus(
	sessionState: SessionState,
	previous: Status,
): Status {
	if (sessionState === "signed-in") {
		if (previous === "logging-in" || previous === "success") {
			return "success";
		}
		return "idle";
	}
	if (sessionState === "expired") {
		if (previous === "logging-in" || previous === "loginError") {
			return previous;
		}
		return "expired";
	}
	if (previous === "logging-in" || previous === "loginError") {
		return previous;
	}
	return "idle";
}
