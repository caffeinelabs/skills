import type { createActorFunction, MockBackendOptions } from "../types";
export declare function useActor<T>(createActor: createActorFunction<T>, options?: MockBackendOptions): {
    actor: NonNullable<import("@tanstack/react-query").NoInfer<T>> | null;
    isFetching: boolean;
};
