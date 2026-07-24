import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ReplicaRejectCode } from "@icp-sdk/core/agent";
import { formatCertificateRejectionError } from "./formatCertificateRejectionError.js";

void describe("formatCertificateRejectionError", () => {
	void it("maps DESTINATION_INVALID missing update method to install guidance", () => {
		const error = formatCertificateRejectionError({
			rejectCode: ReplicaRejectCode.DestinationInvalid,
			rejectMessage:
				"Canister has no update method '_immutableObjectStorageCreateCertificate'.",
		});
		assert.equal(
			error.message,
			"method not found on backend canister; install the caffeineai-object-storage mops package",
		);
	});

	void it("keeps other DESTINATION_INVALID rejects distinct", () => {
		const error = formatCertificateRejectionError({
			rejectCode: ReplicaRejectCode.DestinationInvalid,
			rejectMessage: "Canister not found",
			errorCode: "IC0301",
		});
		assert.match(error.message, /reject_code=3/);
		assert.match(error.message, /reject_message=Canister not found/);
		assert.match(error.message, /error_code=IC0301/);
		assert.doesNotMatch(error.message, /install the caffeineai-object-storage/);
	});

	void it("surfaces CANISTER_ERROR / CANISTER_REJECT with replica details", () => {
		const trap = formatCertificateRejectionError({
			rejectCode: ReplicaRejectCode.CanisterError,
			rejectMessage: "Canister trapped: unreachable",
		});
		assert.match(trap.message, /reject_code=5/);
		assert.match(trap.message, /Canister trapped: unreachable/);

		const explicit = formatCertificateRejectionError({
			rejectCode: ReplicaRejectCode.CanisterReject,
			rejectMessage: "unauthorized",
		});
		assert.match(explicit.message, /reject_code=4/);
		assert.match(explicit.message, /unauthorized/);
	});
});
