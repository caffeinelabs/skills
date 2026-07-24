/**
 * Build an Error for a certified IC call rejection of
 * `_immutableObjectStorageCreateCertificate`.
 *
 * Per the IC interface spec, reject_code is protocol-fixed:
 * - DESTINATION_INVALID (3): invalid destination (missing canister/method)
 * - CANISTER_REJECT (4): explicit canister reject
 * - CANISTER_ERROR (5): trap / canister error
 *
 * Missing update methods surface as DESTINATION_INVALID with a message like
 * `Canister has no update method '...'.` (see execution-errors "Method not found").
 */
export declare function formatCertificateRejectionError(options: {
    rejectCode: number | undefined;
    rejectMessage: string | undefined;
    errorCode?: string;
}): Error;
