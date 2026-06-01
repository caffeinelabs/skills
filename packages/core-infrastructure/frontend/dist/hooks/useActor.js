import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { createActorWithConfig } from "../config";
import { useInternetIdentity } from "./useInternetIdentity";
const ACTOR_QUERY_KEY = "actor";
export function useActor(createActor) {
    const { identity, isAuthenticated } = useInternetIdentity();
    const queryClient = useQueryClient();
    const actorQuery = useQuery({
        queryKey: [ACTOR_QUERY_KEY, identity?.getPrincipal().toString()],
        queryFn: async () => {
            if (!isAuthenticated) {
                return await createActorWithConfig(createActor);
            }
            const actor = await createActorWithConfig(createActor, {
                agentOptions: { identity },
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