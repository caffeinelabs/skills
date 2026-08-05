import type { CreateActorOptions, createActorFunction } from "./types";
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
export declare function createActorWithConfig<T>(createActor: createActorFunction<T>, options?: CreateActorOptions): Promise<T>;
export {};
