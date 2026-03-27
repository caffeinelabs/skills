import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { createActorWithConfig } from "../config";
import type { createActorFunction } from "../types";
import { useInternetIdentity } from "./useInternetIdentity";

interface WithAccessControl {
	_initializeAccessControl(): Promise<void>;
}

function hasAccessControl(actor: unknown): actor is WithAccessControl {
	return (
		typeof actor === "object" &&
		actor !== null &&
		"_initializeAccessControl" in actor
	);
}

const ACTOR_QUERY_KEY = "actor";
export function useActor<T>(createActor: createActorFunction<T>) {
	const { identity } = useInternetIdentity();
	const queryClient = useQueryClient();
	const actorQuery = useQuery<T>({
		queryKey: [ACTOR_QUERY_KEY, identity?.getPrincipal().toString()],
		queryFn: async () => {
			const isAuthenticated = !!identity;

			if (!isAuthenticated) {
				// Return anonymous actor if not authenticated
				return await createActorWithConfig(createActor);
			}

			const actorOptions = {
				agentOptions: {
					identity,
				},
			};

			const actor = await createActorWithConfig(createActor, actorOptions);
			if (hasAccessControl(actor)) {
				await actor._initializeAccessControl();
			}
			return actor;
		},
		// Only refetch when identity changes
		staleTime: Number.POSITIVE_INFINITY,
		// This will cause the actor to be recreated when the identity changes
		enabled: true,
	});

	// When the actor changes, invalidate dependent queries
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
