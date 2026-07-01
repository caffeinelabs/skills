export class ExternalBlob {
	contentType?: string;
	filename?: string;
	getBytes(): Promise<Uint8Array<ArrayBuffer>>;
	getDirectURL(): string;
	static fromURL(url: string): ExternalBlob;
	static fromBytes(
		blob: Uint8Array<ArrayBuffer>,
		contentType?: string,
		filename?: string,
	): ExternalBlob;
	withUploadProgress(onProgress: (percentage: number) => void): ExternalBlob;
}
