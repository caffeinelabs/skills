export class ExternalBlob {
	getBytes(): Promise<Uint8Array<ArrayBuffer>>;
	getDirectURL(): string;
	static fromURL(url: string): ExternalBlob;
	static fromBytes(blob: Uint8Array<ArrayBuffer>): ExternalBlob;
	withUploadProgress(onProgress: (percentage: number) => void): ExternalBlob;
}
