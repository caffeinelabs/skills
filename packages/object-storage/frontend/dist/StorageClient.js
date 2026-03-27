import { isV3ResponseBody } from "@icp-sdk/core/agent";
import { IDL } from "@icp-sdk/core/candid";
const MAXIMUM_CONCURRENT_UPLOADS = 10;
const MAX_RETRIES = 3;
const BASE_DELAY_MS = 1000;
const MAX_DELAY_MS = 30000;
const GATEWAY_VERSION = "v1";
const HASH_ALGORITHM = "SHA-256";
const SHA256_PREFIX = "sha256:";
const DOMAIN_SEPARATOR_FOR_CHUNKS = new TextEncoder().encode("icfs-chunk/");
const DOMAIN_SEPARATOR_FOR_METADATA = new TextEncoder().encode("icfs-metadata/");
const DOMAIN_SEPARATOR_FOR_NODES = new TextEncoder().encode("ynode/");
// Utility function for exponential backoff retry logic - retries on network/server errors only
async function withRetry(operation) {
    let lastError;
    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
        try {
            return await operation();
        }
        catch (error) {
            lastError = error instanceof Error ? error : new Error(String(error));
            // Check if this error should be retried
            const shouldRetry = isRetriableError(error);
            // On the final attempt or non-retriable error, throw the error
            if (attempt === MAX_RETRIES || !shouldRetry) {
                if (!shouldRetry && attempt < MAX_RETRIES) {
                    console.warn(`Non-retriable error encountered: ${lastError.message}. Not retrying.`);
                }
                throw error;
            }
            // Calculate delay with exponential backoff and jitter
            const delay = Math.min(BASE_DELAY_MS * 2 ** attempt + Math.random() * 1000, MAX_DELAY_MS);
            console.warn(`Request failed (attempt ${attempt + 1}/${MAX_RETRIES + 1}): ${lastError.message}. Retrying in ${Math.round(delay)}ms...`);
            await new Promise((resolve) => setTimeout(resolve, delay));
        }
    }
    // This should never happen due to the loop logic, but TypeScript needs it
    throw lastError || new Error("Unknown error occurred during retry attempts");
}
function isRetriableError(error) {
    const errorMessage = error?.message?.toLowerCase() || "";
    // Don't retry client errors (4xx except specific ones)
    if (error?.response?.status) {
        const status = error.response.status;
        // Only retry these 4xx errors
        if (status === 408 || status === 429)
            return true;
        // Don't retry other 4xx client errors
        if (status >= 400 && status < 500)
            return false;
        // Retry 5xx server errors
        if (status >= 500)
            return true;
    }
    // Retry network/SSL errors
    if (errorMessage.includes("ssl") ||
        errorMessage.includes("tls") ||
        errorMessage.includes("network error") ||
        errorMessage.includes("connection") ||
        errorMessage.includes("timeout") ||
        errorMessage.includes("fetch")) {
        return true;
    }
    // Don't retry validation/logic errors
    if (errorMessage.includes("validation") ||
        errorMessage.includes("invalid") ||
        errorMessage.includes("malformed") ||
        errorMessage.includes("unauthorized") ||
        errorMessage.includes("forbidden") ||
        errorMessage.includes("not found")) {
        return false;
    }
    // Default to retry for unknown errors (conservative approach for network issues)
    return true;
}
// Hash validation utility
function validateHashFormat(hash, context) {
    if (!hash) {
        throw new Error(`${context}: Hash cannot be empty`);
    }
    if (!hash.startsWith(SHA256_PREFIX)) {
        throw new Error(`${context}: Invalid hash format. Expected format: ${SHA256_PREFIX}<64-char-hex>, got: ${hash}`);
    }
    const hexPart = hash.substring(SHA256_PREFIX.length); // Remove 'sha256:' prefix
    if (hexPart.length !== 64) {
        throw new Error(`${context}: Invalid hash format. Expected 64 hex characters after ${SHA256_PREFIX}, got ${hexPart.length} characters: ${hash}`);
    }
    if (!/^[0-9a-f]{64}$/i.test(hexPart)) {
        throw new Error(`${context}: Invalid hash format. Hash must contain only hex characters (0-9, a-f), got: ${hash}`);
    }
}
class YHash {
    bytes;
    constructor(bytes) {
        if (bytes.length !== 32) {
            throw new Error(`YHash must be exactly 32 bytes, got ${bytes.length}`);
        }
        this.bytes = new Uint8Array(bytes);
    }
    static async fromNodes(left, right) {
        const leftBytes = left instanceof YHash
            ? left.bytes
            : new TextEncoder().encode("UNBALANCED");
        const rightBytes = right instanceof YHash
            ? right.bytes
            : new TextEncoder().encode("UNBALANCED");
        const combined = new Uint8Array(DOMAIN_SEPARATOR_FOR_NODES.length + leftBytes.length + rightBytes.length);
        const arrays = [DOMAIN_SEPARATOR_FOR_NODES, leftBytes, rightBytes];
        let offset = 0;
        for (const data of arrays) {
            combined.set(data, offset);
            offset += data.length;
        }
        const hashBuffer = await crypto.subtle.digest(HASH_ALGORITHM, combined);
        return new YHash(new Uint8Array(hashBuffer));
    }
    static async fromChunk(data) {
        return YHash.fromBytes(DOMAIN_SEPARATOR_FOR_CHUNKS, data);
    }
    static async fromHeaders(headers) {
        // For each key,value, generate the header line "key: value\n" where the key and value are trimmed.
        const headerLines = [];
        for (const [key, value] of Object.entries(headers)) {
            headerLines.push(`${key.trim()}: ${value.trim()}\n`);
        }
        // Sort the header lines alphabetically.
        headerLines.sort();
        // Hash the header lines, with the metadata domain separator.
        const hash = await YHash.fromBytes(DOMAIN_SEPARATOR_FOR_METADATA, new TextEncoder().encode(headerLines.join("")));
        return hash;
    }
    static async fromBytes(domainSeparator, data) {
        const combined = new Uint8Array(domainSeparator.length + data.length);
        combined.set(domainSeparator);
        combined.set(data, domainSeparator.length);
        const hashBuffer = await crypto.subtle.digest(HASH_ALGORITHM, combined);
        return new YHash(new Uint8Array(hashBuffer));
    }
    static fromHex(hexString) {
        const bytes = new Uint8Array(hexString.match(/.{1,2}/g).map((byte) => Number.parseInt(byte, 16)));
        return new YHash(bytes);
    }
    toShaString() {
        return `${SHA256_PREFIX}${this.toHex()}`;
    }
    toString() {
        throw new Error("toString is not supported for YHash");
    }
    toHex() {
        return Array.from(this.bytes)
            .map((b) => b.toString(16).padStart(2, "0"))
            .join("");
    }
}
function nodeToJSON(node) {
    return {
        hash: node.hash.toShaString(),
        left: node.left ? nodeToJSON(node.left) : null,
        right: node.right ? nodeToJSON(node.right) : null,
    };
}
class BlobHashTree {
    tree_type;
    chunk_hashes;
    tree;
    headers;
    constructor(chunk_hashes, tree, headers = null) {
        this.tree_type = "DSBMTWH";
        this.chunk_hashes = chunk_hashes;
        this.tree = tree;
        if (headers == null) {
            this.headers = [];
        }
        else if (Array.isArray(headers)) {
            this.headers = headers;
        }
        else {
            this.headers = Object.entries(headers).map(([key, value]) => `${key.trim()}: ${value.trim()}`);
        }
        this.headers.sort();
    }
    static async build(chunkHashes, headers = {}) {
        if (chunkHashes.length === 0) {
            // To match rust, we have the hash of nothing
            const hex = "8b8e620f084e48da0be2287fd12c5aaa4dbe14b468fd2e360f48d741fe7628a0";
            const bytes = new TextEncoder().encode(hex);
            chunkHashes.push(new YHash(bytes));
        }
        // Create leaf nodes for each chunk hash
        let level = chunkHashes.map((hash) => ({
            hash,
            left: null,
            right: null,
        }));
        // Build tree bottom-up
        while (level.length > 1) {
            const nextLevel = [];
            for (let i = 0; i < level.length; i += 2) {
                const left = level[i];
                const right = level[i + 1] || null;
                const parentHash = await YHash.fromNodes(left.hash, right ? right.hash : null);
                nextLevel.push({
                    hash: parentHash,
                    left,
                    right,
                });
            }
            level = nextLevel;
        }
        const chunksRoot = level[0];
        // If headers exist and have content, create combined tree
        if (headers && Object.keys(headers).length > 0) {
            const metadataRootHash = await YHash.fromHeaders(headers);
            const metadataRoot = {
                hash: metadataRootHash,
                left: null,
                right: null,
            };
            const combinedRootHash = await YHash.fromNodes(chunksRoot.hash, metadataRoot.hash);
            const combinedRoot = {
                hash: combinedRootHash,
                left: chunksRoot,
                right: metadataRoot,
            };
            return new BlobHashTree(chunkHashes, combinedRoot, headers);
        }
        return new BlobHashTree(chunkHashes, chunksRoot, headers);
    }
    toJSON() {
        return {
            tree_type: this.tree_type,
            chunk_hashes: this.chunk_hashes.map((h) => h.toShaString()),
            tree: nodeToJSON(this.tree),
            headers: this.headers,
        };
    }
}
class StorageGatewayClient {
    storageGatewayUrl;
    constructor(storageGatewayUrl) {
        this.storageGatewayUrl = storageGatewayUrl;
    }
    getStorageGatewayUrl() {
        return this.storageGatewayUrl;
    }
    async uploadChunk(params) {
        // Validate hash formats before sending to server (validation errors should not be retried)
        const blobHashString = params.blobRootHash.toShaString();
        const chunkHashString = params.chunkHash.toShaString();
        validateHashFormat(blobHashString, `uploadChunk[${params.chunkIndex}] blob_hash`);
        validateHashFormat(chunkHashString, `uploadChunk[${params.chunkIndex}] chunk_hash`);
        return await withRetry(async () => {
            // Use query parameters for metadata and raw bytes in body
            const queryParams = new URLSearchParams({
                owner_id: params.owner,
                blob_hash: blobHashString,
                chunk_hash: chunkHashString,
                chunk_index: params.chunkIndex.toString(),
                bucket_name: params.bucketName,
                project_id: params.projectId,
            });
            const url = `${this.storageGatewayUrl}/${GATEWAY_VERSION}/chunk/?${queryParams.toString()}`;
            const response = await fetch(url, {
                method: "PUT",
                headers: {
                    "Content-Type": "application/octet-stream",
                    "X-Caffeine-Project-ID": params.projectId,
                },
                body: params.chunkData,
            });
            if (!response.ok) {
                const errorText = await response.text();
                const error = new Error(`Failed to upload chunk ${params.chunkIndex}: ${response.status} ${response.statusText} - ${errorText}`);
                // Add response status for retry logic
                error.response = { status: response.status };
                throw error;
            }
            const result = (await response.json());
            return {
                isComplete: result.status === "blob_complete",
            };
        });
    }
    async uploadBlobTree(blobHashTree, bucketName, numBlobBytes, owner, projectId, certificateBytes) {
        // Validate all hashes in the tree before sending to server (validation errors should not be retried)
        const treeJSON = blobHashTree.toJSON();
        validateHashFormat(treeJSON.tree.hash, "uploadBlobTree root hash");
        treeJSON.chunk_hashes.forEach((hash, index) => {
            validateHashFormat(hash, `uploadBlobTree chunk_hash[${index}]`);
        });
        return await withRetry(async () => {
            const url = `${this.storageGatewayUrl}/${GATEWAY_VERSION}/blob-tree/`;
            const requestBody = {
                blob_tree: treeJSON,
                bucket_name: bucketName,
                num_blob_bytes: numBlobBytes,
                owner: owner,
                project_id: projectId,
                headers: blobHashTree.headers,
                auth: {
                    OwnerEgressSignature: Array.from(certificateBytes),
                },
            };
            const response = await fetch(url, {
                method: "PUT",
                headers: {
                    "Content-Type": "application/json",
                    "X-Caffeine-Project-ID": projectId,
                },
                body: JSON.stringify(requestBody),
            });
            if (!response.ok) {
                const errorText = await response.text();
                const error = new Error(`Failed to upload blob tree: ${response.status} ${response.statusText} - ${errorText}`);
                // Add response status for retry logic
                error.response = { status: response.status };
                throw error;
            }
        });
    }
}
export class StorageClient {
    bucket;
    backendCanisterId;
    projectId;
    agent;
    storageGatewayClient;
    constructor(bucket, storageGatewayUrl, backendCanisterId, projectId, agent) {
        this.bucket = bucket;
        this.backendCanisterId = backendCanisterId;
        this.projectId = projectId;
        this.agent = agent;
        this.storageGatewayClient = new StorageGatewayClient(storageGatewayUrl);
    }
    async getCertificate(hash) {
        const args = IDL.encode([IDL.Text], [hash]);
        const result = await this.agent.call(this.backendCanisterId, {
            methodName: "_immutableObjectStorageCreateCertificate",
            arg: args,
        });
        const respone = result.response.body;
        if (isV3ResponseBody(respone)) {
            console.log("Certificate:", respone.certificate);
            return respone.certificate;
        }
        throw new Error("Expected v3 response body");
    }
    async putFile(blobBytes, onProgress) {
        // HTTP headers for fetch requests (used for the PUT request to gateway)
        const httpHeaders = {
            "Content-Type": "application/json",
        };
        // Create a Blob from the bytes
        const file = new Blob([new Uint8Array(blobBytes)], {
            type: "application/octet-stream",
        });
        // File metadata headers that will be stored with the blob tree
        const fileHeaders = {
            "Content-Type": "application/octet-stream",
            "Content-Length": file.size.toString(),
        };
        const { chunks, chunkHashes, blobHashTree } = await this.processFileForUpload(file, fileHeaders);
        const blobRootHash = blobHashTree.tree.hash;
        const hashString = blobRootHash.toShaString();
        const certificateBytes = await this.getCertificate(hashString);
        await this.storageGatewayClient.uploadBlobTree(blobHashTree, this.bucket, file.size, this.backendCanisterId, this.projectId, certificateBytes);
        await this.parallelUpload(chunks, chunkHashes, blobRootHash, httpHeaders, onProgress);
        return { hash: hashString };
    }
    async getDirectURL(hash) {
        if (!hash) {
            throw new Error("Hash must not be empty");
        }
        validateHashFormat(hash, `getDirectURL for path '${hash}'`);
        return `${this.storageGatewayClient.getStorageGatewayUrl()}/${GATEWAY_VERSION}/blob/?blob_hash=${encodeURIComponent(hash)}&owner_id=${encodeURIComponent(this.backendCanisterId)}&project_id=${encodeURIComponent(this.projectId)}`;
    }
    async processFileForUpload(file, headers) {
        const chunks = this.createFileChunks(file);
        const chunkHashes = [];
        for (let i = 0; i < chunks.length; i++) {
            const chunkData = new Uint8Array(await chunks[i].arrayBuffer());
            const hash = await YHash.fromChunk(chunkData);
            chunkHashes.push(hash);
        }
        const blobHashTree = await BlobHashTree.build(chunkHashes, headers);
        return { chunks, chunkHashes, blobHashTree };
    }
    async parallelUpload(chunks, chunkHashes, blobRootHash, httpHeaders, onProgress) {
        let completedChunks = 0;
        const uploadSingleChunk = async (index) => {
            const chunkData = new Uint8Array(await chunks[index].arrayBuffer());
            const chunkHash = chunkHashes[index];
            await this.storageGatewayClient.uploadChunk({
                blobRootHash,
                chunkHash,
                chunkIndex: index,
                chunkData,
                bucketName: this.bucket,
                owner: this.backendCanisterId,
                projectId: this.projectId,
                httpHeaders,
            });
            // Use atomic increment to avoid race conditions
            const currentCompleted = ++completedChunks;
            if (onProgress != null) {
                const percentage = chunks.length === 0
                    ? 100
                    : Math.round((currentCompleted / chunks.length) * 100);
                onProgress(percentage);
            }
        };
        await Promise.all(Array.from({ length: MAXIMUM_CONCURRENT_UPLOADS }, async (_, workerId) => {
            for (let i = workerId; i < chunks.length; i += MAXIMUM_CONCURRENT_UPLOADS) {
                await uploadSingleChunk(i);
            }
        }));
    }
    createFileChunks(file, chunkSize = 1024 * 1024) {
        const chunks = [];
        const totalChunks = Math.ceil(file.size / chunkSize);
        for (let index = 0; index < totalChunks; index++) {
            const start = index * chunkSize;
            const end = Math.min(start + chunkSize, file.size);
            const chunk = file.slice(start, end);
            chunks.push(chunk);
        }
        return chunks;
    }
}
//# sourceMappingURL=StorageClient.js.map