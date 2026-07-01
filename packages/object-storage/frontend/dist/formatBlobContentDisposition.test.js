import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { formatBlobContentDisposition } from "./formatBlobContentDisposition.js";
void describe("formatBlobContentDisposition", () => {
    void it("returns undefined for empty input", () => {
        assert.equal(formatBlobContentDisposition(undefined), undefined);
        assert.equal(formatBlobContentDisposition(""), undefined);
        assert.equal(formatBlobContentDisposition("   "), undefined);
    });
    void it("uses unquoted filename for simple names", () => {
        assert.equal(formatBlobContentDisposition("photo.jpg"), "attachment; filename=photo.jpg");
    });
    void it("quotes filenames with spaces or special characters", () => {
        assert.equal(formatBlobContentDisposition("my photo.jpg"), 'attachment; filename="my photo.jpg"');
        assert.equal(formatBlobContentDisposition('say "hi".txt'), 'attachment; filename="say \\"hi\\".txt"');
    });
    void it("uses RFC 5987 encoding for non-ASCII filenames", () => {
        assert.equal(formatBlobContentDisposition("résumé.pdf"), "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf");
        assert.equal(formatBlobContentDisposition("写真.png"), "attachment; filename*=UTF-8''%E5%86%99%E7%9C%9F.png");
        // fully non-ASCII (no ASCII extension)
        assert.equal(formatBlobContentDisposition("写真"), "attachment; filename*=UTF-8''%E5%86%99%E7%9C%9F");
    });
});
//# sourceMappingURL=formatBlobContentDisposition.test.js.map