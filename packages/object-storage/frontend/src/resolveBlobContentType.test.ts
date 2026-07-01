import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { resolveBlobContentType } from "./resolveBlobContentType.js";

// JPEG: FF D8 FF E0 (JFIF APP0 marker)
const JPEG_BYTES = new Uint8Array([
	0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46,
]);
const EMPTY_BYTES = new Uint8Array([]);
const UNKNOWN_BYTES = new Uint8Array([0x00, 0x01, 0x02, 0x03]);

void describe("resolveBlobContentType", () => {
	void it("returns hint when provided", async () => {
		assert.equal(
			await resolveBlobContentType(JPEG_BYTES, "image/png"),
			"image/png",
		);
	});

	void it("trims whitespace from hint", async () => {
		assert.equal(
			await resolveBlobContentType(JPEG_BYTES, "  image/png  "),
			"image/png",
		);
	});

	void it("sniffs bytes when hint is application/octet-stream", async () => {
		assert.equal(
			await resolveBlobContentType(JPEG_BYTES, "application/octet-stream"),
			"image/jpeg",
		);
	});

	void it("sniffs bytes when hint is absent", async () => {
		assert.equal(await resolveBlobContentType(JPEG_BYTES), "image/jpeg");
	});

	void it("sniffs bytes when hint is whitespace-only", async () => {
		assert.equal(await resolveBlobContentType(JPEG_BYTES, "   "), "image/jpeg");
	});

	void it("falls back to application/octet-stream for unrecognised bytes", async () => {
		assert.equal(
			await resolveBlobContentType(UNKNOWN_BYTES),
			"application/octet-stream",
		);
	});

	void it("falls back to application/octet-stream for empty bytes", async () => {
		assert.equal(
			await resolveBlobContentType(EMPTY_BYTES),
			"application/octet-stream",
		);
	});
});
