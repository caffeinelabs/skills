import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
	II_MAINNET_CANISTER_ID,
	nextLoginStatus,
	normalizeAuthorizeUrl,
	resolveAttributeKeys,
	resolveIdentityProvider,
} from "./internetIdentityAuth.js";

void describe("normalizeAuthorizeUrl", () => {
	it("forces /authorize on an origin-only URL", () => {
		assert.equal(
			normalizeAuthorizeUrl("https://id.ai"),
			"https://id.ai/authorize",
		);
	});

	it("keeps /authorize when already present", () => {
		assert.equal(
			normalizeAuthorizeUrl("http://id.ai.localhost:8000/authorize"),
			"http://id.ai.localhost:8000/authorize",
		);
	});

	it("replaces a non-authorize path", () => {
		assert.equal(
			normalizeAuthorizeUrl("http://localhost:5173/home"),
			"http://localhost:5173/authorize",
		);
	});
});

void describe("resolveIdentityProvider", () => {
	it("omits the option when nothing names a deployment", () => {
		assert.equal(resolveIdentityProvider(), undefined);
	});

	it("uses env URL + canister when II_URL is set", () => {
		assert.deepEqual(
			resolveIdentityProvider({
				envUrl: "http://id.ai.localhost:8000",
				envCanisterId: "rdmx6-jaaaa-aaaaa-aaadq-cai",
			}),
			{
				authorizeUrl: "http://id.ai.localhost:8000/authorize",
				canisterId: "rdmx6-jaaaa-aaaaa-aaadq-cai",
			},
		);
	});

	it("defaults the env canister to mainnet II", () => {
		assert.deepEqual(resolveIdentityProvider({ envUrl: "https://id.ai" }), {
			authorizeUrl: "https://id.ai/authorize",
			canisterId: II_MAINNET_CANISTER_ID,
		});
	});
});

void describe("resolveAttributeKeys", () => {
	it("uses explicit keys when provided", () => {
		assert.deepEqual(
			resolveAttributeKeys({ keys: ["email"] }, { provider: "google" }),
			["email"],
		);
	});

	it("scopes SSO keys to the domain", () => {
		assert.deepEqual(resolveAttributeKeys({}, { ssoDomain: "Acme.com" }), [
			"sso:acme.com:name",
			"sso:acme.com:email",
		]);
	});

	it("scopes OpenID keys to the provider", () => {
		assert.deepEqual(resolveAttributeKeys({}, { provider: "google" }), [
			"openid:https://accounts.google.com:name",
			"openid:https://accounts.google.com:email",
			"openid:https://accounts.google.com:verified_email",
		]);
	});

	it("defaults to verified_email for plain II", () => {
		assert.deepEqual(resolveAttributeKeys({}), ["verified_email"]);
	});
});

void describe("nextLoginStatus", () => {
	it("treats a restored sign-in as idle, not success", () => {
		assert.equal(nextLoginStatus("signed-in", "initializing"), "idle");
		assert.equal(nextLoginStatus("signed-in", "idle"), "idle");
	});

	it("promotes an interactive login to success", () => {
		assert.equal(nextLoginStatus("signed-in", "logging-in"), "success");
		assert.equal(nextLoginStatus("signed-in", "success"), "success");
	});

	it("maps an ended session to expired, not idle", () => {
		assert.equal(nextLoginStatus("expired", "idle"), "expired");
		assert.equal(nextLoginStatus("expired", "success"), "expired");
		assert.equal(nextLoginStatus("expired", "initializing"), "expired");
	});

	it("does not clobber an in-flight login or a reported error", () => {
		assert.equal(nextLoginStatus("signed-out", "logging-in"), "logging-in");
		assert.equal(nextLoginStatus("signed-out", "loginError"), "loginError");
		assert.equal(nextLoginStatus("expired", "logging-in"), "logging-in");
		assert.equal(nextLoginStatus("expired", "loginError"), "loginError");
	});

	it("treats signed-in-elsewhere as signed-out for the hook", () => {
		assert.equal(nextLoginStatus("signed-in-elsewhere", "idle"), "idle");
		assert.equal(nextLoginStatus("signed-in-elsewhere", "success"), "idle");
		assert.equal(
			nextLoginStatus("signed-in-elsewhere", "logging-in"),
			"logging-in",
		);
	});

	it("returns idle after a deliberate or other-tab sign-out", () => {
		assert.equal(nextLoginStatus("signed-out", "success"), "idle");
		assert.equal(nextLoginStatus("signed-out", "idle"), "idle");
	});
});
