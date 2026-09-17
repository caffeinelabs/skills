import type { CreateActorOptions, createActorFunction, MockBackendOptions, MockModules } from "./types.js";
interface Config {
    backend_host?: string;
    backend_canister_id: string;
    storage_gateway_url: string;
    bucket_name: string;
    project_id: string;
    ii_derivation_origin?: string;
}
/**
 * Synchronous access to the config cached by a previous `loadConfig()` call.
 * Needed by code paths that must stay inside a user-activation window (e.g.
 * opening the Internet Identity popup from a click handler) and therefore
 * cannot await. Returns `null` if `loadConfig()` has not completed yet.
 */
export declare function getCachedConfig(): Config | null;
export declare function loadConfig(): Promise<Config>;
/**
 * Load the app's mock backend when `VITE_USE_MOCK=true`.
 * Pass `import.meta.glob("./mocks/backend.{ts,tsx,js,jsx}")` evaluated in app source:
 * Vite resolves the pattern relative to the file containing the call,
 * so a glob inside this package can never see the app's files.
 * Globbing (instead of a static import) keeps builds green when the mock file is absent.
 */
export declare function loadMockBackendFromModules<T>(mockModules: MockModules): Promise<T | null>;
export declare function createActorWithConfig<T>(createActor: createActorFunction<T>, options?: CreateActorOptions & MockBackendOptions): Promise<T>;
export {};
