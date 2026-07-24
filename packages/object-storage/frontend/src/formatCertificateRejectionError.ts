import { ReplicaRejectCode } from "@icp-sdk/core/agent";

const CERTIFICATE_METHOD = "_immutableObjectStorageCreateCertificate";

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
export function formatCertificateRejectionError(options: {
	rejectCode: number | undefined;
	rejectMessage: string | undefined;
	errorCode?: string;
}): Error {
	const { rejectCode, rejectMessage, errorCode } = options;

	const isMissingUpdateMethod =
		rejectCode === ReplicaRejectCode.DestinationInvalid &&
		typeof rejectMessage === "string" &&
		/has no update method/i.test(rejectMessage);

	if (isMissingUpdateMethod) {
		return new Error(
			`method not found on backend canister; install the caffeineai-object-storage mops package`,
		);
	}

	const details = [
		rejectCode !== undefined ? `reject_code=${rejectCode}` : undefined,
		rejectMessage ? `reject_message=${rejectMessage}` : undefined,
		errorCode ? `error_code=${errorCode}` : undefined,
	]
		.filter((part): part is string => part !== undefined)
		.join(", ");

	return new Error(
		details.length > 0
			? `backend canister rejected ${CERTIFICATE_METHOD} (${details})`
			: `backend canister rejected ${CERTIFICATE_METHOD}`,
	);
}
