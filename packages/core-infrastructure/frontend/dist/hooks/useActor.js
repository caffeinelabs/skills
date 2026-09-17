import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { createActorWithConfig } from "../config.js";
import { useInternetIdentity } from "./useInternetIdentity.js";
const ACTOR_QUERY_KEY = "actor";
export function useActor(createActor, options) {
    const { identity, isAuthenticated } = useInternetIdentity();
    const queryClient = useQueryClient();
    const mockModules = options?.mockModules;
    const actorQuery = useQuery({
        queryKey: [ACTOR_QUERY_KEY, identity?.getPrincipal().toString()],
        queryFn: async () => {
            if (!isAuthenticated) {
                return await createActorWithConfig(createActor, { mockModules });
            }
            const actor = await createActorWithConfig(createActor, {
                agentOptions: { identity },
                mockModules,
            });
            return actor;
        },
        // Only refetch when identity changes
        staleTime: Number.POSITIVE_INFINITY,
        // This will cause the actor to be recreated when the identity changes
        enabled: true,
    });
    useEffect(() => {
        if (actorQuery.data) {
            queryClient.invalidateQueries({
                predicate: (query) => {
                    return !query.queryKey.includes(ACTOR_QUERY_KEY);
                },
            });
            queryClient.refetchQueries({
                predicate: (query) => {
                    return !query.queryKey.includes(ACTOR_QUERY_KEY);
                },
            });
        }
    }, [actorQuery.data, queryClient]);
    return {
        actor: actorQuery.data || null,
        isFetching: actorQuery.isFetching,
    };
}
//# sourceMappingURL=useActor.js.map