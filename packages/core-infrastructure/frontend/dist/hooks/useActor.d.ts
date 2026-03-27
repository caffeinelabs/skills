import type { createActorFunction } from "../types";
export declare function useActor<T>(createActor: createActorFunction<T>): {
    actor: NonNullable<import("@tanstack/react-query").NoInfer<T>> | null;
    isFetching: boolean;
};
