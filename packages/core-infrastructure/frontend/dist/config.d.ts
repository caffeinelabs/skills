import type { CreateActorOptions, createActorFunction } from "./types";
interface Config {
    backend_host?: string;
    backend_canister_id: string;
    storage_gateway_url: string;
    bucket_name: string;
    project_id: string;
    ii_derivation_origin?: string;
}
export declare function loadConfig(): Promise<Config>;
export declare function createActorWithConfig<T>(createActor: createActorFunction<T>, options?: CreateActorOptions): Promise<T>;
export {};
