import { fileTypeFromBuffer } from "file-type";
const DEFAULT_CONTENT_TYPE = "application/octet-stream";
function isUsableContentType(contentType) {
    if (!contentType) {
        return false;
    }
    const trimmed = contentType.trim();
    return trimmed.length > 0 && trimmed !== DEFAULT_CONTENT_TYPE;
}
export async function resolveBlobContentType(bytes, hint) {
    if (isUsableContentType(hint)) {
        return hint.trim();
    }
    const detected = await fileTypeFromBuffer(bytes);
    return detected?.mime ?? DEFAULT_CONTENT_TYPE;
}
//# sourceMappingURL=resolveBlobContentType.js.map