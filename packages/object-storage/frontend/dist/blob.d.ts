export declare class ExternalBlob {
    _blob?: Uint8Array<ArrayBuffer> | null;
    directURL: string;
    onProgress?: (percentage: number) => void;
    private constructor();
    static fromURL(url: string): ExternalBlob;
    static fromBytes(blob: Uint8Array<ArrayBuffer>): ExternalBlob;
    getBytes(): Promise<Uint8Array<ArrayBuffer>>;
    getDirectURL(): string;
    withUploadProgress(onProgress: (percentage: number) => void): ExternalBlob;
}
