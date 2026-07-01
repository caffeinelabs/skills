/** Value for the `Content-Disposition` blob-tree header (gateway-persisted metadata). */
export function formatBlobContentDisposition(filename) {
    const trimmed = filename?.trim();
    if (!trimmed) {
        return undefined;
    }
    // Unquoted token: only safe unreserved ASCII chars
    if (/^[A-Za-z0-9._-]+$/.test(trimmed)) {
        return `attachment; filename=${trimmed}`;
    }
    // Non-ASCII: RFC 5987 percent-encoded extended value
    if (/[^\x20-\x7E]/.test(trimmed)) {
        return `attachment; filename*=UTF-8''${encodeURIComponent(trimmed)}`;
    }
    // ASCII with special chars: quoted-string
    const escaped = trimmed.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    return `attachment; filename="${escaped}"`;
}
//# sourceMappingURL=formatBlobContentDisposition.js.map