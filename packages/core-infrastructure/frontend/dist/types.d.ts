import type { ExternalBlob } from "@caffeineai/object-storage";
import type { ActorConfig, Agent, HttpAgentOptions } from "@icp-sdk/core/agent";
export interface CreateActorOptions {
    agent?: Agent;
    agentOptions?: HttpAgentOptions;
    actorOptions?: ActorConfig;
    processError?: (error: unknown) => never;
}
export type createActorFunction<T> = (canisterId: string, uploadFile: (file: ExternalBlob) => Promise<Uint8Array>, downloadFile: (file: Uint8Array) => Promise<ExternalBlob>, options: CreateActorOptions) => T;
export type MockModules = Record<string, () => Promise<unknown>>;
export interface MockBackendOptions {
    /**
     * Result of `import.meta.glob("./mocks/backend.{ts,tsx,js,jsx}")` evaluated in the app.
     * The matched module must export `mockBackend`; it is used only when `VITE_USE_MOCK=true`.
     */
    mockModules?: MockModules;
}
