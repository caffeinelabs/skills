export declare class ExternalBlob {
    _blob?: Uint8Array<ArrayBuffer> | null;
    directURL: string;
    contentType?: string;
    filename?: string;
    onProgress?: (percentage: number) => void;
    private constructor();
    static fromURL(url: string): ExternalBlob;
    static fromBytes(blob: Uint8Array<ArrayBuffer>, contentType?: string, filename?: string): ExternalBlob;
    getBytes(): Promise<Uint8Array<ArrayBuffer>>;
    getDirectURL(): string;
    withUploadProgress(onProgress: (percentage: number) => void): ExternalBlob;
}
