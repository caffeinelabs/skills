import { type HttpAgent } from "@icp-sdk/core/agent";
export declare class StorageClient {
    private readonly bucket;
    private readonly backendCanisterId;
    private readonly projectId;
    private readonly agent;
    private readonly storageGatewayClient;
    constructor(bucket: string, storageGatewayUrl: string, backendCanisterId: string, projectId: string, agent: HttpAgent);
    private getCertificate;
    putFile(blobBytes: Uint8Array, onProgress?: (percentage: number) => void): Promise<{
        hash: string;
    }>;
    getDirectURL(hash: string): Promise<string>;
    private processFileForUpload;
    private parallelUpload;
    private createFileChunks;
}
