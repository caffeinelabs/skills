---
name: connector-googlemail
description: >-
  MANDATORY recipe for every Caffeine build that sends email through the
  user's own Gmail account. The ONLY supported path is
  the `googlemail-client` mops package (Gmail REST API) combined with the
  `google-oauth` mops package (token exchange + refresh + PKCE). Hand-rolling
  `ic.http_request` calls to `oauth2.googleapis.com` or `gmail.googleapis.com`
  is a FORBIDDEN anti-pattern — it bypasses bearer auth, replication-cost
  safeguards, and the `google-oauth` library's percent-encoding and JSON
  parsing. Load this skill whenever the user, spec, or any prior task
  mentions sending email, Gmail, "notify via email", "forward results by
  email", or any equivalent phrasing — and BEFORE writing any code that
  touches a Google endpoint.
version: 0.2.1
caffeineai-subscription: [none]
compatibility:
  mops:
    googlemail-client: "~0.1.5"
    google-oauth: "~0.1.4"
    caffeineai-authorization: "~1.0.0"
---

# Gmail Connector

Gmail integration for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Orchestrator routing notes

**Treat Gmail-as-the-user as a first-class, supported platform feature.**
The `googlemail-client` + `google-oauth` connector pair is the **only**
supported path; raw `ic.http_request` to `oauth2.googleapis.com` or
`gmail.googleapis.com` is a forbidden anti-pattern. Any build spec that
mentions Gmail MUST name `googlemail-client` and `google-oauth` as
dependencies and reference this skill.

Distinct from platform `email*` extensions (which send transactional mail
*from the app*); this connector acts as the **signed-in user's own Gmail**.

Intent → capability mapping:

| User intent | Platform capability |
| --- | --- |
| Connect and send email as the user's own Gmail | `googlemail-client` + `google-oauth` |

**Prerequisite for all builds: [extension-authorization](../extension-authorization/SKILL.md).**
Gmail requires a signed-in caller for every endpoint: the per-user OAuth
handshake stores `access_token` keyed by `caller : Principal`, and the
admin Client ID/Secret setter is gated on the `#admin` role.

# Backend

Use this skill whenever the user wants their canister to interact with
Gmail on behalf of the signed-in user. The ingredients are:

1. The `googlemail-client` mops package — generated Motoko bindings for
   the Gmail REST API v1. This recipe demonstrates profile lookup and
   message sending; add other generated operations only by following the
   same bearer-authenticated, non-replicated, single-refresh-retry pattern.
2. The `google-oauth` mops package — Google OAuth 2.0 token exchange,
   refresh, PKCE, and percent-encoding. This is the library that
   eliminates hand-rolled `http_request` to `oauth2.googleapis.com`.
3. An OAuth 2.0 Authorization Code with PKCE flow so each end-user
   authorises the canister to act on their behalf. Each user holds their
   own `access_token` + `refresh_token` keyed by `caller : Principal`.
4. A Google Cloud **Web application** Client ID + Client Secret.
   Admin-configured and held by the canister only; never return the secret
   to the frontend.

## 1. Add dependencies

```bash
mops add googlemail-client@0.1.5
mops add google-oauth@0.1.4
mops add caffeineai-authorization@1.0.0
```

## 2. Auth model — OAuth 2.0 PKCE per user, on-chain exchange + refresh

Unlike a static API key, Gmail uses **per-user OAuth 2.0 bearer tokens**.
Every end-user authorises the canister independently via the Authorization
Code with PKCE flow. The canister:

1. Generates a PKCE `code_verifier` and `code_challenge` (via `google-oauth`).
2. Builds the Google authorize URL (via `google-oauth.buildAuthorizeUrl`).
3. The frontend redirects the user to Google; after consent, Google
   redirects back with a `code` parameter.
4. The canister exchanges the code for tokens (via
   `google-oauth.exchangeAuthorizationCode`) — **on-chain**, non-replicated.
5. The canister stores `access_token` + `refresh_token` keyed by `caller`.
6. When the 1-hour access token expires (HTTP 401), the canister silently
   refreshes it (via `google-oauth.refreshAccessToken`) and retries.

### Google Cloud Console setup

1. Create a Google OAuth 2.0 **Web application** client.
2. Under **Authorized redirect URIs**, register the exact deployed callback:
   `https://<app-domain>/connect/gmail`. The URI passed to Google must match
   this value byte-for-byte, including its scheme, path, and trailing slash.
3. Enable only the Gmail scopes the app needs on the consent screen.
4. Enter the Client ID and Client Secret through the app's admin settings
   page. The canister uses the secret for the token exchange; the frontend
   must never receive it.

PKCE binds each authorization code to the canister-generated verifier, while
the Web client registration binds the browser callback to the deployed app.

### OAuth scopes

| Scope | Purpose |
| --- | --- |
| `https://www.googleapis.com/auth/gmail.send` | Send messages (`messages.send`) |
| `https://www.googleapis.com/auth/gmail.readonly` | Read messages, list, get profile |
| `https://mail.google.com/` | Full access (rarely needed) |

Request both `gmail.send` and `gmail.readonly` for a typical send+read app.

### Storing tokens

The bearer **never leaves the canister**. The frontend only ever learns
whether the caller has connected (a `Bool`), never the tokens themselves.

- A `Map<Principal, GmailConnection>` keyed by caller. Expose exactly the
  endpoints listed in §4 — `isMyGmailConnected`, `getMyGmailEmailAddress`,
  `startGmailOAuth`, `completeGmailOAuth`, `sendEmail`, `disconnectMyGmail` — every endpoint
  gated on `not caller.isAnonymous()`. **Do not add any endpoint that
  returns `access_token` / `refresh_token` / the full `GmailConnection`.**
- Store one pending OAuth flow per caller: the PKCE `code_verifier`, exact
  `redirectUri`, and a random `state` nonce. Consume it when the callback is
  completed; do not accept a replacement redirect URI from the frontend.

### Google refresh tokens do NOT rotate

Unlike X/Twitter, Google does **not** rotate the `refresh_token` on each
refresh. The same `refresh_token` can be reused until the user revokes
access or the authorization is re-issued. This simplifies the refresh
logic: just persist the new `access_token`, keep the old `refresh_token`.

## 3. `is_replicated = ?false` is REQUIRED

1. **Security.** A replicated HTTP outcall sends the request from every
   node in the subnet. Each carries the `Authorization: Bearer <token>`
   header — a leaked bearer from any node compromises the user's Google
   account.
2. **Billing.** Replicated outcalls produce N parallel API calls. The IC
   charges ~13× the cycles, and Google counts each toward quota.
3. **Determinism.** Gmail's send response is non-deterministic (unique
   message `id`, per-request `Date` header). Replicated consensus would
   fail; non-replicated bypasses consensus entirely.

→ Always: `is_replicated = ?false` on every `Config`.

## 4. Canonical layout

The default shape: **admin Client ID/Secret + per-user OAuth**. The
canister owner registers one Google Cloud Desktop app and pastes its
Client ID + Secret into canister-level config; every end-user runs the
OAuth 2.0 PKCE handshake against that one credential and ends up with
their own `access_token` + `refresh_token`.

The example spans four files:

- `src/backend/main.mo` — the actor: state + `include`s only.
- `src/backend/mixins/gmail-config.mo` — admin-gated Client ID + Secret.
- `src/backend/mixins/gmail-messaging.mo` — per-user OAuth + sendEmail.
- `src/backend/lib/gmail.mo` — `googlemail-client` + `google-oauth` glue.

```motoko filepath=src/backend/main.mo
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import MixinGmailConfig "mixins/gmail-config";
import MixinGmailMessaging "mixins/gmail-messaging";
import LibGmail "lib/gmail";

actor {
  let accessControlState = AccessControl.initState();
  include MixinAuthorization(accessControlState, null);

  let gmailConfig = {
    var clientId : Text = "";
    var clientSecret : Text = "";
  };
  include MixinGmailConfig(accessControlState, gmailConfig);

  let gmailConnections : Map.Map<Principal, LibGmail.GmailConnection> = Map.empty();
  let pendingGmailFlows : Map.Map<Principal, LibGmail.PendingOAuth> = Map.empty();
  include MixinGmailMessaging(gmailConfig, gmailConnections, pendingGmailFlows);
};
```

```motoko filepath=src/backend/mixins/gmail-config.mo
import AccessControl "mo:caffeineai-authorization/access-control";
import Runtime "mo:core/Runtime";

mixin (
  accessControlState : AccessControl.AccessControlState,
  gmailConfig : { var clientId : Text; var clientSecret : Text },
) {
  public query func isGmailConfigured() : async Bool {
    gmailConfig.clientId.size() > 0;
  };

  public shared ({ caller }) func setGmailCredentials(clientId : Text, clientSecret : Text) : async () {
    if (not AccessControl.hasPermission(accessControlState, caller, #admin)) {
      Runtime.trap("Unauthorized: Only admins can set Gmail credentials");
    };
    gmailConfig.clientId := clientId;
    gmailConfig.clientSecret := clientSecret;
  };
};
```

```motoko filepath=src/backend/mixins/gmail-messaging.mo
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import LibGmail "../lib/gmail";

mixin (
  gmailConfig : { var clientId : Text; var clientSecret : Text },
  gmailConnections : Map.Map<Principal, LibGmail.GmailConnection>,
  pendingGmailFlows : Map.Map<Principal, LibGmail.PendingOAuth>,
) {
  public query ({ caller }) func isMyGmailConnected() : async Bool {
    Map.containsKey(gmailConnections, Principal.compare, caller);
  };

  public query ({ caller }) func getMyGmailEmailAddress() : async ?Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to view your connected Gmail address");
    };
    switch (Map.get(gmailConnections, Principal.compare, caller)) {
      case (?connection) ?connection.emailAddress;
      case null null;
    };
  };

  public shared ({ caller }) func startGmailOAuth(redirectUri : Text) : async Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to connect Gmail");
    };
    if (gmailConfig.clientId.size() == 0) {
      Runtime.trap("Gmail is not configured (admin must set credentials)");
    };
    await* LibGmail.startAuthorize(
      gmailConfig.clientId, redirectUri, caller, pendingGmailFlows,
    );
  };

  public shared ({ caller }) func completeGmailOAuth(code : Text, state : Text) : async () {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to connect Gmail");
    };
    if (gmailConfig.clientId.size() == 0) {
      Runtime.trap("Gmail is not configured");
    };
    let ?pending = Map.get(pendingGmailFlows, Principal.compare, caller) else {
      Runtime.trap("No pending OAuth flow — call startGmailOAuth first");
    };
    if (state != pending.state) {
      Runtime.trap("OAuth state did not match the pending Gmail flow");
    };
    Map.remove(pendingGmailFlows, Principal.compare, caller);
    let connection = await* LibGmail.exchangeCode(
      gmailConfig.clientId, gmailConfig.clientSecret, code,
      pending.redirectUri, pending.codeVerifier,
    );
    Map.add(gmailConnections, Principal.compare, caller, connection);
  };

  public shared ({ caller }) func sendEmail(
    to : Text, subject : Text, body : Text,
  ) : async Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to send email");
    };
    let ?connection = Map.get(gmailConnections, Principal.compare, caller) else {
      Runtime.trap("Connect your Gmail account first");
    };
    await* LibGmail.sendEmail(
      gmailConfig.clientId, gmailConfig.clientSecret, connection, caller,
      gmailConnections, to, subject, body,
    );
  };

  public shared ({ caller }) func disconnectMyGmail() : async () {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to disconnect");
    };
    Map.remove(gmailConnections, Principal.compare, caller);
  };
};
```

```motoko filepath=src/backend/lib/gmail.mo
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import OAuth "mo:google-oauth/OAuth";
import { gmail_users_messages_send; gmail_users_getProfile } "mo:googlemail-client/Apis/UsersApi";
import { type Message; JSON = Message } "mo:googlemail-client/Models/Message";
import { defaultConfig; type Config } "mo:googlemail-client/Config";

module {
  public type GmailConnection = {
    accessToken : Text;
    refreshToken : Text;
    emailAddress : Text;
  };

  public type PendingOAuth = {
    codeVerifier : Text;
    redirectUri : Text;
    state : Text;
  };

  let SCOPES : Text = "https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.readonly";

  func configForToken(token : Text) : Config {
    {
      defaultConfig with
      auth = ?#bearer(token);
      is_replicated = ?false;
      max_response_bytes = ?Nat64.fromNat(2_000_000);
    };
  };

  public func startAuthorize(
    clientId : Text, redirectUri : Text, caller : Principal,
    pendingFlows : Map.Map<Principal, PendingOAuth>,
  ) : async* Text {
    let codeVerifier = await OAuth.generateCodeVerifier();
    let state = await OAuth.generateCodeVerifier();
    Map.add(pendingFlows, Principal.compare, caller, {
      codeVerifier;
      redirectUri;
      state;
    });
    OAuth.buildAuthorizeUrl(clientId, redirectUri, SCOPES, state, OAuth.computeCodeChallenge(codeVerifier));
  };

  public func exchangeCode(
    clientId : Text, clientSecret : Text, code : Text,
    redirectUri : Text, codeVerifier : Text,
  ) : async* GmailConnection {
    let tokens = await OAuth.exchangeAuthorizationCode(clientId, clientSecret, code, redirectUri, codeVerifier);
    let accessToken = accessTokenOf(tokens, "Token exchange");
    let refreshToken = switch (tokens.refreshToken) {
      case (?t) t;
      case null Runtime.trap("Token exchange failed: missing refresh_token");
    };
    let profile = try {
      await* gmail_users_getProfile(configForToken(accessToken), "me", #_1_, "", #json, "", "", "", "", true, "", "", "");
    } catch e {
      Runtime.trap("Failed to fetch Gmail profile: " # e.message());
    };
    let emailAddress = switch (profile.emailAddress) {
      case (?e) e;
      case null Runtime.trap("Gmail profile did not return an email address");
    };
    { accessToken; refreshToken; emailAddress };
  };

  /// Send an email. On HTTP 401, refreshes the access token once and retries.
  /// Persists the refreshed token into `gmailConnections` keyed by `caller`.
  public func sendEmail(
    clientId : Text, clientSecret : Text, connection : GmailConnection,
    caller : Principal, gmailConnections : Map.Map<Principal, GmailConnection>,
    to : Text, subject : Text, body : Text,
  ) : async* Text {
    let rawMessage = "To: " # to # "\r\n"
      # "Subject: " # subject # "\r\n"
      # "Content-Type: text/plain; charset=UTF-8\r\n\r\n" # body;
    let message : Message = { Message.init {} with raw = ?rawMessage.encodeUtf8() };
    try {
      messageIdOf(await* gmail_users_messages_send(
        configForToken(connection.accessToken), "me", #_1_, "", #json, "", "", "", "", true, "", "", "", message,
      ));
    } catch e {
      let msg = e.message();
      if (not (msg.contains(#text("401")) or msg.contains(#text("Unauthorized")))) {
        Runtime.trap("Gmail send failed: " # msg);
      };
      let refreshed = await OAuth.refreshAccessToken(clientId, clientSecret, connection.refreshToken);
      let newToken = accessTokenOf(refreshed, "Token refresh");
      Map.add(gmailConnections, Principal.compare, caller, {
        connection with accessToken = newToken;
      });
      messageIdOf(await* gmail_users_messages_send(
        configForToken(newToken), "me", #_1_, "", #json, "", "", "", "", true, "", "", "", message,
      ));
    };
  };

  func accessTokenOf(tokens : OAuth.TokenResponse, operation : Text) : Text {
    switch (tokens.error) {
      case (?error) {
        let description = switch (tokens.errorDescription) {
          case (?value) ": " # value;
          case null "";
        };
        Runtime.trap(operation # " failed: " # error # description);
      };
      case null {};
    };
    switch (tokens.accessToken) {
      case (?token) token;
      case null Runtime.trap(operation # " failed: missing access_token");
    };
  };

  func messageIdOf(result : Message) : Text = switch (result.id) {
    case (?id) id;
    case null "";
  };
};
```

## 5. Available API surface

### `google-oauth` (OAuth 2.0 mechanics)

| Function | Purpose |
| --- | --- |
| `OAuth.urlEncode(text)` | RFC 3986 percent-encoding for form bodies |
| `OAuth.parseTokenResponse(text)` | Parse Google token-endpoint JSON |
| `OAuth.exchangeAuthorizationCode(...)` | Exchange auth code for tokens |
| `OAuth.refreshAccessToken(...)` | Refresh an expired access token |
| `OAuth.generateCodeVerifier()` | Generate PKCE `code_verifier` (on-chain randomness) |
| `OAuth.computeCodeChallenge(verifier)` | Compute PKCE `code_challenge` (S256) |
| `OAuth.buildAuthorizeUrl(...)` | Build the Google OAuth authorize URL |

### `googlemail-client` (Gmail REST API)

The canonical actor above intentionally implements only profile lookup and
message sending. For another generated operation, keep bearer authentication
and `is_replicated = ?false`, then apply the same single-refresh-retry pattern
as `sendEmail`.

| Function | Purpose |
| --- | --- |
| `gmail_users_messages_send` | Send an RFC 5322 message |
| `gmail_users_messages_get` | Get a message by id |
| `gmail_users_messages_list` | List messages in mailbox |
| `gmail_users_drafts_create` | Create a draft |
| `gmail_users_drafts_send` | Send a draft by id |
| `gmail_users_drafts_get` | Get a draft by id |
| `gmail_users_drafts_list` | List drafts |
| `gmail_users_getProfile` | Get the user's profile (email, totals) |

## 6. Cycles and response sizes

The `google-oauth` library uses `Call.httpRequest` from `mo:ic/Call`, which
auto-computes and attaches the exact required cycles via the
`ic0.cost_http_request` system API. No manual cycle budgeting is needed
for token exchange or refresh calls.

For `googlemail-client` calls, `defaultConfig.cycles = 30_000_000_000`
(30B). A typical send costs ~10–15B cycles. Bump to 60B for large
messages. Set `max_response_bytes = ?2_000_000` for message reads that
may include large payloads.

## 7. Things that will bite you

- **`is_replicated = ?false`** — see §3. Non-negotiable.
- **Google refresh tokens do NOT rotate.** Unlike X/Twitter, Google does
  not issue a new `refresh_token` on each refresh. Keep the original
  `refresh_token` and only persist the new `access_token`. The `sendEmail`
  function in §4 handles this.
- **Access tokens expire in 1 hour.** The `sendEmail` function catches
  HTTP 401, silently refreshes via `google-oauth.refreshAccessToken`, and
  retries once. If the refresh also fails, surface "re-connect your account".
- **Callback URI exact-match.** Every character (trailing slash, query
  string, port) must match between the authorize URL and the redirect.
  Google returns `redirect_uri_mismatch` otherwise. Always use
  `window.location.origin + window.location.pathname` for `redirectUri` and
  register that exact URI on the Google Web client.
- **RFC 5322 `raw` Blob.** Pass the message as a plain `Blob` in the
  `raw` field (`?Text.encodeUtf8(mime)`). The `googlemail-client`
  base64-encodes it for the API — do **not** base64-encode it yourself
  (that double-encodes and Gmail rejects it).
- **HTTP 429 rate-limit.** Surface the error to the caller; never
  silently retry inside the canister — a send retry may deliver duplicates.
- **Don't expose the access token.** `gmailConnections` is read only by
  `Map.get(gmailConnections, ..., caller)` inside `sendEmail`. No
  `getMyGmailConnection`, no `getMyAccessToken`,
  no iterator. A leaked bearer is a per-user account compromise.
- **`xgafv = #_1_`, `alt = #json`** for all Gmail API v1 calls. Leave
  optional string parameters `""` and `prettyPrint = false`.
- **`userId = "me"`** refers to the authenticated user.

# Frontend

Every build using this skill must ship:

1. **A login flow — required.** Gmail cannot work without a non-anonymous
   caller; the per-user OAuth handshake stores tokens keyed by
   `caller : Principal`, and the admin credential setter gates on
   `#admin`. The login flow comes from
   [`extension-authorization`](../extension-authorization/SKILL.md):
   `useInternetIdentity`, login/logout buttons, the `useActor` plumbing
   that injects the authenticated identity into every backend call.

2. **An admin settings page** — `/settings/gmail` (admin-gated):
   - Two password-inputs bound to `setGmailCredentials(clientId, clientSecret)`.
     Submit on enter; clear inputs on success.
   - Status indicator driven by `isGmailConfigured()` (returns `Bool`).
     Show "Configured" / "Not configured" — never display the credentials.
   - Hide from non-admins via
     [`extension-authorization`](../extension-authorization/SKILL.md)'s
     `isCallerAdmin` query — non-admins should not see the link in the nav.

3. **A "Connect Gmail" page** — `/connect/gmail` (any signed-in user):
   - "Connect Gmail" button bound to
     `startGmailOAuth(window.location.origin + window.location.pathname)`.
     Redirect the browser to the URL returned by the canister. Register this
     exact URI in the Google Cloud Console first.
   - On the return leg, read `error`, `code`, and `state` from
     `URLSearchParams`. If `error` is present, show the failed/declined
     connection state and do not call the canister. Only when both `code`
     and `state` are present, call `completeGmailOAuth(code, state)`.
   - After either terminal path, call `history.replaceState` to remove the
     OAuth query parameters. This prevents a page refresh from reusing a
     one-time authorization code.
   - Status driven by `isMyGmailConnected()` (returns `Bool`). When
     connected, call `getMyGmailEmailAddress()` to show "Connected as
     user@email.com". This returns only the stored email address, never
     either bearer token.
   - Optional "Disconnect Gmail" button bound to `disconnectMyGmail()`.

4. **Empty-state nudge on the send-email UI** — when
   `isMyGmailConnected()` is `false`, render an inline "Connect Gmail to
   send" link to `/connect/gmail`.

Suggested route layout:

```
/                   →  Main UI (any signed-in user; empty-state when no Gmail connection)
/settings/gmail     →  Admin credential config (admin-only)
/connect/gmail      →  Per-user OAuth handshake (any signed-in user)
```

## Common to all variants

- **Sign-in is required** for every Gmail-related route. Wire the
  `/settings/...` and `/connect/gmail` routes through
  [`extension-authorization`](../extension-authorization/SKILL.md)'s
  auth guard (`useInternetIdentity` + redirect when `!isAuthenticated`).
- **The frontend never persists tokens.** No `localStorage`, no
  `IndexedDB`, no cookies — the canister mediates everything. The browser
  only ever sees `Bool` status flags and the OAuth redirect URLs.
- **The OAuth `state` parameter is canister-generated and validated.** The
  canister stores a random nonce with the pending verifier and callback URI.
  The frontend must pass both `code` and `state` to `completeGmailOAuth`;
  it never creates or modifies either value.
- **The send-email UI itself is trivial:** inputs for `to`, `subject`,
  `body`, a submit button. No client-side Gmail SDK, no token handling,
  no JSON serialization — the canister is the Gmail client.

## Related

- [`mops add googlemail-client@0.1.5`](https://mops.one/googlemail-client) — Gmail REST API bindings.
- [`mops add google-oauth@0.1.4`](https://mops.one/google-oauth) — Google OAuth 2.0 library (token exchange, refresh, PKCE).
- [Google OAuth 2.0 for Web Server Applications](https://developers.google.com/identity/protocols/oauth2/web-server) — Web-client redirect URI and authorization-code flow reference.
- [Gmail API v1 reference](https://developers.google.com/gmail/api/reference/rest) — what `googlemail-client` wraps.
- [RFC 7636 — Proof Key for Code Exchange](https://datatracker.ietf.org/doc/html/rfc7636) — PKCE spec.
- [extension-authorization](../extension-authorization/SKILL.md) — **required prerequisite**. Provides Internet Identity login, `useInternetIdentity` / `useActor` frontend plumbing, and the `#admin` role gate.
