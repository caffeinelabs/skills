import { ExternalBlob, StorageClient } from "@caffeineai/object-storage";
import { HttpAgent } from "@icp-sdk/core/agent";
const DEFAULT_BUCKET_NAME = "default-bucket";
const DEFAULT_PROJECT_ID = "0000000-0000-0000-0000-00000000000";
let configCache = null;
/**
 * Synchronous access to the config cached by a previous `loadConfig()` call.
 * Needed by code paths that must stay inside a user-activation window (e.g.
 * opening the Internet Identity popup from a click handler) and therefore
 * cannot await. Returns `null` if `loadConfig()` has not completed yet.
 */
export function getCachedConfig() {
    return configCache;
}
export async function loadConfig() {
    if (configCache) {
        return configCache;
    }
    const backendCanisterId = process.env.CANISTER_ID_BACKEND;
    const envBaseUrl = process.env.BASE_URL || "/";
    const baseUrl = envBaseUrl.endsWith("/") ? envBaseUrl : `${envBaseUrl}/`;
    try {
        const response = await fetch(`${baseUrl}env.json`);
        const config = (await response.json());
        if (!backendCanisterId && config.backend_canister_id === "undefined") {
            console.error("CANISTER_ID_BACKEND is not set");
            throw new Error("CANISTER_ID_BACKEND is not set");
        }
        const runtimeStorageGatewayUrl = config.storage_gateway_url && config.storage_gateway_url !== "undefined"
            ? config.storage_gateway_url
            : undefined;
        const fullConfig = {
            backend_host: config.backend_host === "undefined" ? undefined : config.backend_host,
            backend_canister_id: (config.backend_canister_id === "undefined"
                ? backendCanisterId
                : config.backend_canister_id),
            storage_gateway_url: runtimeStorageGatewayUrl ?? "nogateway",
            bucket_name: DEFAULT_BUCKET_NAME,
            project_id: config.project_id !== "undefined"
                ? config.project_id
                : DEFAULT_PROJECT_ID,
            ii_derivation_origin: config.ii_derivation_origin === "undefined"
                ? undefined
                : config.ii_derivation_origin,
        };
        configCache = fullConfig;
        return fullConfig;
    }
    catch {
        if (!backendCanisterId) {
            console.error("CANISTER_ID_BACKEND is not set");
            throw new Error("CANISTER_ID_BACKEND is not set");
        }
        const fallbackConfig = {
            backend_host: undefined,
            backend_canister_id: backendCanisterId,
            storage_gateway_url: "nogateway",
            bucket_name: DEFAULT_BUCKET_NAME,
            project_id: DEFAULT_PROJECT_ID,
            ii_derivation_origin: undefined,
        };
        return fallbackConfig;
    }
}
function extractAgentErrorMessage(error) {
    const errorString = String(error);
    const match = errorString.match(/with message:\s*'([^']+)'/s);
    return match ? match[1] : errorString;
}
function processError(e) {
    if (e && typeof e === "object" && "message" in e) {
        throw new Error(extractAgentErrorMessage(`${e.message}`));
    }
    throw e;
}
/**
 * Load the app's mock backend when `VITE_USE_MOCK=true`.
 * Pass `import.meta.glob("./mocks/backend.{ts,tsx,js,jsx}")` evaluated in app source:
 * Vite resolves the pattern relative to the file containing the call,
 * so a glob inside this package can never see the app's files.
 * Globbing (instead of a static import) keeps builds green when the mock file is absent.
 */
export async function loadMockBackendFromModules(mockModules) {
    if (import.meta.env.VITE_USE_MOCK !== "true") {
        return null;
    }
    const load = Object.values(mockModules)[0];
    if (!load)
        return null;
    try {
        const mod = (await load());
        return mod.mockBackend ?? null;
    }
    catch {
        return null;
    }
}
export async function createActorWithConfig(createActor, options) {
    const { mockModules, ...resolvedOptions } = options ?? {};
    if (mockModules) {
        const mock = await loadMockBackendFromModules(mockModules);
        if (mock) {
            return mock;
        }
    }
    const config = await loadConfig();
    const agent = new HttpAgent({
        ...resolvedOptions.agentOptions,
        host: config.backend_host,
    });
    if (config.backend_host?.includes("localhost")) {
        await agent.fetchRootKey().catch((err) => {
            console.warn("Unable to fetch root key. Check to ensure that your local replica is running");
            console.error(err);
        });
    }
    const actorOptions = {
        ...resolvedOptions,
        agent: agent,
        processError,
    };
    const storageClient = new StorageClient(config.bucket_name, config.storage_gateway_url, config.backend_canister_id, config.project_id, agent);
    const MOTOKO_DEDUPLICATION_SENTINEL = "!caf!";
    const uploadFile = async (file) => {
        const { hash } = await storageClient.putFile(await file.getBytes(), file.onProgress, file.contentType, file.filename);
        return new TextEncoder().encode(MOTOKO_DEDUPLICATION_SENTINEL + hash);
    };
    const downloadFile = async (bytes) => {
        const hashWithPrefix = new TextDecoder().decode(new Uint8Array(bytes));
        const hash = hashWithPrefix.substring(MOTOKO_DEDUPLICATION_SENTINEL.length);
        const url = await storageClient.getDirectURL(hash);
        return ExternalBlob.fromURL(url);
    };
    return createActor(config.backend_canister_id, uploadFile, downloadFile, actorOptions);
}
//# sourceMappingURL=config.js.map