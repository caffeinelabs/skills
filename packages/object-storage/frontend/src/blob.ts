export class ExternalBlob {
	_blob?: Uint8Array<ArrayBuffer> | null;
	directURL: string;
	contentType?: string;
	filename?: string;
	onProgress?: (percentage: number) => void = undefined;
	private constructor(directURL: string, blob: Uint8Array<ArrayBuffer> | null) {
		if (blob) {
			this._blob = blob;
		}
		this.directURL = directURL;
	}
	static fromURL(url: string): ExternalBlob {
		return new ExternalBlob(url, null);
	}
	static fromBytes(
		blob: Uint8Array<ArrayBuffer>,
		contentType?: string,
		filename?: string,
	): ExternalBlob {
		const url = URL.createObjectURL(
			new Blob([new Uint8Array(blob)], {
				type: contentType?.trim() || "application/octet-stream",
			}),
		);
		const externalBlob = new ExternalBlob(url, blob);
		if (contentType?.trim()) {
			externalBlob.contentType = contentType.trim();
		}
		if (filename?.trim()) {
			externalBlob.filename = filename.trim();
		}
		return externalBlob;
	}
	public async getBytes(): Promise<Uint8Array<ArrayBuffer>> {
		if (this._blob) {
			return this._blob;
		}
		const response = await fetch(this.directURL);
		const blob = await response.blob();
		this._blob = new Uint8Array(await blob.arrayBuffer());
		return this._blob;
	}
	public getDirectURL(): string {
		return this.directURL;
	}
	public withUploadProgress(
		onProgress: (percentage: number) => void,
	): ExternalBlob {
		this.onProgress = onProgress;
		return this;
	}
}
