export class ExternalBlob {
    _blob;
    directURL;
    contentType;
    filename;
    onProgress = undefined;
    constructor(directURL, blob) {
        if (blob) {
            this._blob = blob;
        }
        this.directURL = directURL;
    }
    static fromURL(url) {
        return new ExternalBlob(url, null);
    }
    static fromBytes(blob, contentType, filename) {
        const url = URL.createObjectURL(new Blob([new Uint8Array(blob)], {
            type: contentType?.trim() || "application/octet-stream",
        }));
        const externalBlob = new ExternalBlob(url, blob);
        if (contentType?.trim()) {
            externalBlob.contentType = contentType.trim();
        }
        if (filename?.trim()) {
            externalBlob.filename = filename.trim();
        }
        return externalBlob;
    }
    async getBytes() {
        if (this._blob) {
            return this._blob;
        }
        const response = await fetch(this.directURL);
        const blob = await response.blob();
        this._blob = new Uint8Array(await blob.arrayBuffer());
        return this._blob;
    }
    getDirectURL() {
        return this.directURL;
    }
    withUploadProgress(onProgress) {
        this.onProgress = onProgress;
        return this;
    }
}
//# sourceMappingURL=blob.js.map