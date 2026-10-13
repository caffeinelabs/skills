export interface EmailVerificationActor {
    _caffeineEmailConfirmVerification(token: string): Promise<{
        ok: string;
    } | {
        err: string;
    }>;
}
export type EmailVerificationStatus = "ready" | "pending" | "done" | "invalid" | "error";
export declare function useEmailVerification(actor: EmailVerificationActor | null | undefined): {
    status: EmailVerificationStatus;
    email: string | null;
    error: string | null;
    hasToken: boolean;
    isReady: boolean;
    confirm: () => Promise<void>;
};
