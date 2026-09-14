export {
	createActorWithConfig,
	loadConfig,
	loadMockBackendFromModules,
} from "./config";
export { useActor } from "./hooks/useActor";
export {
	type InternetIdentityContext,
	InternetIdentityProvider,
	type LoginOptions,
	type Status,
	useInternetIdentity,
} from "./hooks/useInternetIdentity";
export type {
	CreateActorOptions,
	createActorFunction,
	MockBackendOptions,
	MockModules,
} from "./types";
