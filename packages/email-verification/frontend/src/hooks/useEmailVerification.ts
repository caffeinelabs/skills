import { useCallback, useEffect, useState } from "react";

// The slice of the generated backend actor the hook calls: the method the
// `caffeineai-email-verification` mixin adds to the app canister.
export interface EmailVerificationActor {
	_caffeineEmailConfirmVerification(
		token: string,
	): Promise<{ ok: string } | { err: string }>;
}

// `ready`: a token is in the URL and nothing was sent yet.
// `pending`: the backend call is in flight.
// `done`: the address is verified; `email` holds it.
// `invalid`: the URL has no token, or the backend rejected it.
// `error`: the backend call failed; `error` holds the message.
export type EmailVerificationStatus =
	| "ready"
	| "pending"
	| "done"
	| "invalid"
	| "error";

const TOKEN_PARAM = "token";

function tokenFromLocation(): string | null {
	if (typeof window === "undefined") return null;
	return new URLSearchParams(window.location.search).get(TOKEN_PARAM);
}

// Nothing happens on page load: mail clients, link previewers and scanners
// fetch the landing URL without a person behind it. The backend runs only
// from `confirm()`, wired to a button the recipient clicks.
export function useEmailVerification(
	actor: EmailVerificationActor | null | undefined,
) {
	const [token, setToken] = useState<string | null>(null);
	const [status, setStatus] = useState<EmailVerificationStatus>("invalid");
	const [email, setEmail] = useState<string | null>(null);
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		const found = tokenFromLocation();
		setToken(found);
		setStatus(found ? "ready" : "invalid");
	}, []);

	const confirm = useCallback(async () => {
		if (!actor || !token || status === "pending" || status === "done") return;
		setStatus("pending");
		setError(null);
		try {
			const result = await actor._caffeineEmailConfirmVerification(token);
			if ("ok" in result) {
				setEmail(result.ok);
				setStatus("done");
			} else {
				setError(result.err);
				setStatus("invalid");
			}
		} catch (cause) {
			setError(cause instanceof Error ? cause.message : String(cause));
			setStatus("error");
		}
	}, [actor, token, status]);

	return {
		status,
		email,
		error,
		hasToken: token !== null,
		isReady: actor != null && token !== null && status === "ready",
		confirm,
	};
}
