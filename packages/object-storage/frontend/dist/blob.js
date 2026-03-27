export class ExternalBlob {
    _blob;
    directURL;
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
    static fromBytes(blob) {
        const url = URL.createObjectURL(new Blob([new Uint8Array(blob)], {
            type: "application/octet-stream",
        }));
        return new ExternalBlob(url, blob);
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