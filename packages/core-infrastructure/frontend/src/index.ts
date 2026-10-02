export {
	createActorWithConfig,
	loadConfig,
	loadMockBackendFromModules,
} from "./config.js";
export { useActor } from "./hooks/useActor.js";
export {
	type InternetIdentityContext,
	type InternetIdentityCreateOptions,
	InternetIdentityProvider,
	type LoginOptions,
	type Status,
	useInternetIdentity,
} from "./hooks/useInternetIdentity.js";
export type {
	CreateActorOptions,
	createActorFunction,
	MockBackendOptions,
	MockModules,
} from "./types.js";
