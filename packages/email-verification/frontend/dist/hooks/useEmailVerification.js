import { useCallback, useEffect, useState } from "react";
const TOKEN_PARAM = "token";
function tokenFromLocation() {
    if (typeof window === "undefined")
        return null;
    return new URLSearchParams(window.location.search).get(TOKEN_PARAM);
}
// Nothing happens on page load: mail clients, link previewers and scanners
// fetch the landing URL without a person behind it. The backend runs only
// from `confirm()`, wired to a button the recipient clicks.
export function useEmailVerification(actor) {
    const [token, setToken] = useState(null);
    const [status, setStatus] = useState("invalid");
    const [email, setEmail] = useState(null);
    const [error, setError] = useState(null);
    useEffect(() => {
        const found = tokenFromLocation();
        setToken(found);
        setStatus(found ? "ready" : "invalid");
    }, []);
    const confirm = useCallback(async () => {
        if (!actor || !token || status === "pending" || status === "done")
            return;
        setStatus("pending");
        setError(null);
        try {
            const result = await actor._caffeineEmailConfirmVerification(token);
            if ("ok" in result) {
                setEmail(result.ok);
                setStatus("done");
            }
            else {
                setError(result.err);
                setStatus("invalid");
            }
        }
        catch (cause) {
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
//# sourceMappingURL=useEmailVerification.js.map