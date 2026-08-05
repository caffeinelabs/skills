---
name: extension-core-infrastructure
description: Core infrastructure providing backend connection configuration, storage client, and React app entry point.
version: 1.2.0
compatibility:
  npm:
    "@caffeineai/core-infrastructure": "^1.2.0"
    "@caffeineai/object-storage": "^1.1.0"
caffeineai-subscription: [none]
---

# Core Infrastructure
Core infrastructure extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This component provides the foundational infrastructure for all projects: backend connection configuration, Internet Identity authentication hooks, and actor management utilities.

## Requirements

```
"@caffeineai/core-infrastructure": "^1.2.0"
"@caffeineai/object-storage": "^1.1.0"
"@icp-sdk/auth": "^7.1.0"
"@icp-sdk/core": "^5.3.0"
```

`@caffeineai/object-storage` is a peer dependency of core-infrastructure. Every project must install it as a direct npm dependency (the build template includes both packages).

## Integration

Core infrastructure is automatically included in every project. No manual integration steps are required.

# Frontend

The core-infrastructure frontend package (`@caffeineai/core-infrastructure`) is automatically included in every project.

## App Entry Point

Wrap the app with `InternetIdentityProvider` and `QueryClientProvider`:

```typescript
import { InternetIdentityProvider } from "@caffeineai/core-infrastructure";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import ReactDOM from "react-dom/client";
import App from "./App";

const queryClient = new QueryClient();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <QueryClientProvider client={queryClient}>
    <InternetIdentityProvider>
      <App />
    </InternetIdentityProvider>
  </QueryClientProvider>,
);
```

## `useInternetIdentity()` — Authentication Hook

Provides identity state, login, and logout for Internet Identity.

### Return Values

| Field | Type | Description |
|---|---|---|
| `identity` | `Identity \| undefined` | The user's identity (available after login or session restore) |
| `login` | `(options?: LoginOptions) => void` | Opens the II popup. Fire-and-forget — do not `await`. See [Sign-in variants](#sign-in-variants-plain-ii-google-workspace-sso). |
| `clear` | `() => void` | Logs out and clears stored identity. Fire-and-forget. |
| `isAuthenticated` | `boolean` | `true` when user has a valid identity. **Use this for UI gating.** |
| `isInitializing` | `boolean` | `true` while `AuthClient` is loading from IndexedDB |
| `isLoggingIn` | `boolean` | `true` while the II popup is open |
| `isLoginSuccess` | `boolean` | `true` only after interactive login (NOT after page reload restore) |
| `isLoginError` | `boolean` | `true` if login or initialization failed |
| `loginError` | `Error \| undefined` | The error object when `isLoginError` is `true` |

### Auth State Lifecycle

| Scenario | `loginStatus` | `isAuthenticated` |
|---|---|---|
| Page load, no stored session | `"idle"` | `false` |
| Restoring stored session | `"initializing"` | `false` → `true` |
| Stored session restored after reload | `"idle"` | `true` |
| Interactive login in progress | `"logging-in"` | `false` |
| Interactive login just completed | `"success"` | `true` |
| Login popup failed / cancelled | `"loginError"` | `false` |

**IMPORTANT:** `isLoginSuccess` is only `true` after an interactive login via the popup — NOT when a stored identity is restored on page reload. Always use `isAuthenticated` for conditional rendering.

### Usage

Gate authenticated UI on `isAuthenticated`:
```typescript
const { isAuthenticated } = useInternetIdentity();

{isAuthenticated ? <AuthenticatedApp /> : <LoginScreen />}
```

Disable the login button while initializing or logging in:
```typescript
const { login, isInitializing, isLoggingIn } = useInternetIdentity();

<button onClick={() => login()} disabled={isInitializing || isLoggingIn}>
  Sign in
</button>
```

`login()` and `clear()` are fire-and-forget — the hook's state fields (`isLoggingIn`, `isInitializing`) track the async lifecycle. Do not wrap them in local `useState` / `isPending` logic.

### Sign-in variants: plain II, Google, workspace SSO

`login()` accepts an optional `LoginOptions` object selecting how the user signs in. All variants go through Internet Identity and produce the same identity, session behavior, and logout — they only change which screen the user sees first:

```typescript
login();                            // Plain Internet Identity sign-in
login({ provider: "google" });      // One-click Google sign-in (II opens Google OAuth directly)
login({ ssoDomain: "acme.com" });   // Company/workspace SSO via the domain's identity provider
```

- **Google**: no Google API keys or OAuth client setup is needed — Internet Identity handles the OAuth flow.
- **Workspace SSO**: the user enters their company domain (e.g. `acme.com`); Internet Identity discovers the company's OpenID Connect provider from `https://<domain>/.well-known/ii-openid-configuration` and signs in against it (works with Okta, Entra ID, and other OIDC providers the company has configured).
- Sessions from all variants are stored the same way: `isAuthenticated`, session restore on reload, and `clear()` behave identically regardless of the variant used.
- When the backend uses `caffeineai-authorization`, Google and SSO sign-ins carry verified name/email attributes (and the SSO domain) to the attribute callback automatically — see the `extension-authorization` skill.

**Call `login()` only from a button's `onClick` handler.** The Internet Identity popup can only be opened while a real click event is dispatching; anything else fails with `Signer window should not be opened outside of click handler`. In particular:

- Never call `login()` from a form's `onSubmit` — the `submit` event fires *after* the click event has finished, so the check fails. For the SSO domain field, use a plain `<div>` (not a `<form>`) and a `type="button"` submit button whose `onClick` validates the domain and calls `login({ ssoDomain })` directly.
- Never call `login()` from keyboard handlers (e.g. Enter in the domain input) or after an `await` — both run outside the click dispatch.

If the app validates the SSO domain before calling `login`, mirror Internet Identity's own rules: accept a normal DNS name with at least two labels (e.g. `acme.com`) **or** a loopback host — `localhost` or `127.0.0.1`, with an optional `:port` (e.g. `localhost:3000`). II accepts loopback domains for local testing, so the input must not reject them.

Standard sign-in UI pattern — a prominent Google button, plain II sign-in, and a "company SSO" option that prompts for a domain:

```typescript
function SignInOptions() {
  const { login, isInitializing, isLoggingIn } = useInternetIdentity();
  const [ssoDomain, setSsoDomain] = useState("");
  const disabled = isInitializing || isLoggingIn;

  return (
    <div>
      <button onClick={() => login({ provider: "google" })} disabled={disabled}>
        Continue with Google
      </button>
      <button onClick={() => login()} disabled={disabled}>
        Sign in with Internet Identity
      </button>
      {/* Company SSO: deliberately not a <form> — login must run inside the
          button's click event, and form onSubmit fires after the click ends */}
      <input
        value={ssoDomain}
        onChange={(e) => setSsoDomain(e.target.value)}
        placeholder="yourcompany.com"
      />
      <button
        onClick={() => login({ ssoDomain: ssoDomain.trim() })}
        disabled={disabled || !ssoDomain.trim()}
      >
        Sign in with your company
      </button>
    </div>
  );
}
```

Only offer the variants the app actually needs: default to plain `login()` unless Google or company SSO sign-in was requested. When Google or company SSO **is** requested, the sign-in page must show the requested direct sign-in option (Google button and/or SSO domain input) **and** keep a plain "Sign in with Internet Identity" button as a fallback — users without a Google account or a registered company domain must still be able to sign in.

## `useActor()` — Backend Actor Hook

Creates and manages a typed backend actor instance. Automatically re-creates the actor when the user's identity changes (login/logout).

```typescript
import { useActor } from "@caffeineai/core-infrastructure";
import { createActor } from "declarations/backend";

function MyComponent() {
  const { actor, isFetching } = useActor(createActor);

  // actor is null while loading, then the typed backend actor
  if (!actor || isFetching) return <Loading />;

  // Call backend methods directly
  const data = await actor.myBackendMethod();
}
```

### Return Values

| Field | Type | Description |
|---|---|---|
| `actor` | `T \| null` | The typed backend actor, or `null` while loading |
| `isFetching` | `boolean` | `true` while the actor is being created |

When the identity changes (login, logout, or session restore), the actor is automatically re-created with the new identity and all dependent queries are invalidated and refetched.
