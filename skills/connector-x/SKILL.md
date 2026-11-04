---
name: connector-x
description: >-
  MANDATORY recipe for every Caffeine build that posts to or reads from X
  (Twitter) from a canister: tweets, replies, reposts, quote posts, timelines,
  mentions, search and user lookup. The supported path is the `x-client` mops
  package (X API v2) over outbound HTTPS, with per-user OAuth 2.0 (PKCE, no
  client secret). Hand-rolling `ic.http_request` calls to `api.x.com` is a
  FORBIDDEN anti-pattern — it bypasses bearer auth, the
  non-replicated-outcall safeguard, and the package's null-field JSON handling.
  Load this skill whenever the user, spec, or any prior task mentions X or
  Twitter, posting a tweet, "tweet this", sharing to X, X mentions, an X
  timeline or X search — and BEFORE writing any code that touches an X endpoint.
version: 0.5.0
caffeineai-subscription: [none]
compatibility:
  mops:
    x-client: "~0.5.0"
    caffeineai-authorization: "~1.0.0"
---

# X (Twitter) with `x-client`

Motoko bindings for the [X API v2](https://developer.x.com/en/docs/x-api),
generated from X's OpenAPI spec. This skill covers every X feature of an app,
writes and reads alike; never route X reads through `extension-http-outcalls`.

| Need | Call |
|---|---|
| Post a tweet (reply, quote, poll) | `TweetsApi.createPosts` (`POST /2/tweets`) |
| Delete a tweet | `TweetsApi.deletePosts` |
| Repost / like | `UsersApi.repostPost`, `UsersApi.likePost` |
| Search recent tweets (mentions of `@handle`, hashtags) | `TweetsApi.searchPostsRecent` |
| A user's mentions / own tweets / home timeline | `TweetsApi.getUsersMentions`, `getUsersPosts`, `getUsersTimeline` |
| Look up a user / the connected user | `UsersApi.getUsersByUsername`, `UsersApi.getUsersMe` |

# Backend

**Prerequisite: [extension-authorization](../extension-authorization/SKILL.md).**
Every X call carries the bearer token of a signed-in user, stored keyed by
`caller : Principal`, and the Client ID setter is gated on the `#admin` role.
Without sign-in `caller.isAnonymous()` is always true and every endpoint traps.

## OAuth 2.0 setup — PKCE, no client secret

Every endpoint needs a **per-user OAuth 2.0 bearer token**. `x-client` is built
for the **PKCE** flow, so there is **no client secret** — only a public
**Client ID**.

1. Visit the [X Developer Portal](https://developer.x.com/en/portal/dashboard),
   create a Project (Free tier = 1500 posts/month), and an **App**.
2. App → **Settings → User authentication settings → Edit**, toggle **OAuth 2.0**
   on. **Type of App**: `Web App, Automated App or Bot` (PKCE). Do **not** pick
   `Native App` or a "Confidential Client" — those force a client-secret flow this
   client does not emit.
3. **Callback URI**: your canister's HTTPS endpoint receiving `?code=…`, exact
   string match (e.g. `https://<canister-id>.ic0.app/connect/x`).
4. **Scopes** to request at authorise-time:

   | Scope | Why |
   |---|---|
   | `tweet.write` | **Required** for `createPosts` / posting |
   | `tweet.read` | **Required** for search, mentions and timelines |
   | `users.read` | User lookup and "connected as @…" |
   | `offline.access` | Issue a **refresh token** (access tokens last ~2 h) |

5. Save; copy the **OAuth 2.0 Client ID** (a ~30-char public string). It is **not
   a secret**, but only an admin may set it.

Scopes are requested at authorise-time but silently absent from the issued token
if unticked — "Insufficient OAuth scope" almost always means a scope was missing.

## Canonical layout — admin Client ID + per-user OAuth

The canister owner registers one X Developer App and an admin pastes its Client
ID; every end-user runs the PKCE handshake against it and holds their own
`access_token` + `refresh_token`. The example spans five files:

- `src/backend/main.mo` — the actor: state + `include`s only.
- `src/backend/migrations/00000000_000000.mo` — the migration chain head.
- `src/backend/mixins/x-config.mo` — admin Client ID (`isXClientIdConfigured`, `setXClientId`).
- `src/backend/mixins/x-account.mo` — per-user OAuth, posting and reading (`isMyXConnected`, `startXOAuth`, `completeXOAuth`, `tweet`, `searchX`, `disconnectMyX`).
- `src/backend/lib/x.mo` — `x-client` glue (`Config` builder, `createPosts` and `searchPostsRecent` round-trips, token-refresh stubs).

```motoko filepath=src/backend/main.mo
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import MixinXConfig "mixins/x-config";
import MixinXAccount "mixins/x-account";
import LibX "lib/x";

actor {
  let accessControlState : AccessControl.AccessControlState;
  include MixinAuthorization(accessControlState, null);

  // Public identifier, but admin-set so a user can't redirect every call
  // through their own Developer App.
  let xClientId : { var value : ?Text };
  include MixinXConfig(accessControlState, xClientId);

  // Per-user OAuth tokens. Never iterated except by the calling principal.
  let xAuthByUser : Map.Map<Principal, LibX.XAuth>;
  include MixinXAccount(xClientId, xAuthByUser);
};
```

```motoko filepath=src/backend/migrations/00000000_000000.mo
import Map "mo:core/Map";
import AccessControl "mo:caffeineai-authorization/access-control";

module {
  type XAuth = {
    access_token : Text;
    refresh_token : Text;
    expires_at : Nat64;
    scope : [Text];
  };

  type NewActor = {
    accessControlState : AccessControl.AccessControlState;
    xClientId : { var value : ?Text };
    xAuthByUser : Map.Map<Principal, XAuth>;
  };

  public func migration(_old : {}) : NewActor {
    {
      accessControlState = AccessControl.initState();
      xClientId = { var value : ?Text = null };
      xAuthByUser = Map.empty<Principal, XAuth>();
    };
  };
};
```

```motoko filepath=src/backend/mixins/x-config.mo
import AccessControl "mo:caffeineai-authorization/access-control";
import Runtime "mo:core/Runtime";

mixin (
  accessControlState : AccessControl.AccessControlState,
  xClientId : { var value : ?Text },
) {
  public query func isXClientIdConfigured() : async Bool {
    xClientId.value != null;
  };

  public shared ({ caller }) func setXClientId(id : Text) : async () {
    if (not AccessControl.hasPermission(accessControlState, caller, #admin)) {
      Runtime.trap("Unauthorized: Only admins can set the X Client ID");
    };
    xClientId.value := ?id;
  };
};
```

```motoko filepath=src/backend/mixins/x-account.mo
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import LibX "../lib/x";

mixin (
  xClientId : { var value : ?Text },
  xAuthByUser : Map.Map<Principal, LibX.XAuth>,
) {
  public query ({ caller }) func isMyXConnected() : async Bool {
    Map.containsKey(xAuthByUser, Principal.compare, caller);
  };

  // Begin PKCE: returns the X authorise URL the frontend redirects to.
  public shared ({ caller }) func startXOAuth(redirectUri : Text) : async Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to connect X");
    };
    let ?clientId = xClientId.value else {
      Runtime.trap("X is not configured (admin must set the Client ID)");
    };
    await* LibX.startAuthorize(clientId, redirectUri, caller);
  };

  public shared ({ caller }) func completeXOAuth(code : Text, redirectUri : Text) : async () {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to connect X");
    };
    let ?clientId = xClientId.value else {
      Runtime.trap("X is not configured");
    };
    let auth = await* LibX.exchangeCode(clientId, code, redirectUri, caller);
    Map.add(xAuthByUser, Principal.compare, caller, auth);
  };

  // The caller's fresh bearer; persists the rotated pair after a refresh.
  func tokenFor(caller : Principal) : async* Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to use X");
    };
    let ?clientId = xClientId.value else {
      Runtime.trap("X is not configured");
    };
    let ?auth = Map.get(xAuthByUser, Principal.compare, caller) else {
      Runtime.trap("Connect your X account first");
    };
    let fresh = await* LibX.ensureFreshToken(clientId, auth);
    if (fresh.access_token != auth.access_token) {
      Map.add(xAuthByUser, Principal.compare, caller, fresh);
    };
    fresh.access_token;
  };

  public shared ({ caller }) func tweet(body : Text) : async Text {
    let token = await* tokenFor(caller);
    await* LibX.runCreatePost(LibX.configForToken(token), body);
  };

  // Outcalls cannot run in a query, so reads are update calls too.
  public shared ({ caller }) func searchX(searchQuery : Text) : async [LibX.Post] {
    let token = await* tokenFor(caller);
    await* LibX.runSearchRecent(LibX.configForToken(token), searchQuery);
  };

  public shared ({ caller }) func disconnectMyX() : async () {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to disconnect");
    };
    Map.remove(xAuthByUser, Principal.compare, caller);
  };
};
```

```motoko filepath=src/backend/lib/x.mo
import { defaultConfig; type Config } "mo:x-client/Config";
import TweetsApi "mo:x-client/Apis/TweetsApi";
import TweetCreateRequest "mo:x-client/Models/TweetCreateRequest";
import { type Tweet } "mo:x-client/Models/Tweet";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";

module {
  public type XAuth = {
    access_token : Text;
    refresh_token : Text;
    expires_at : Nat64; // ns absolute (Time.now()-relative)
    scope : [Text];
  };

  public type Post = { id : Text; text : Text; authorId : ?Text };

  public func configForToken(token : Text) : Config {
    { defaultConfig with auth = ?#bearer token };
  };

  public func runCreatePost(config : Config, body : Text) : async* Text {
    let req = { TweetCreateRequest.init {} with text_ = ?body };
    let resp = await* TweetsApi.createPosts(config, req);
    let ?data = resp.data else Runtime.trap("createPosts returned no data");
    data.id;
  };

  // Recent tweets (last 7 days) matching an X search query, e.g. "@BeanThereCafe".
  // Empty strings and 0 leave an optional parameter out; max_results is 10..100.
  public func runSearchRecent(config : Config, searchQuery : Text) : async* [Post] {
    let resp = await* TweetsApi.searchPostsRecent(config, searchQuery, "", "", "", "", 10, "", "", null, [], [], [], [], [], []);
    let ?tweets = resp.data else return [];
    Array.filterMap<Tweet, Post>(
      tweets,
      func(t) {
        switch (t.id, t.text_) {
          case (?id, ?text) ?{ id; text; authorId = t.author_id };
          case _ null;
        };
      },
    );
  };

  // ------------------------------------------------------------------
  // OAuth 2.0 PKCE. `x-client` ships only the API surface; the handshake
  // uses `ic.http_request` directly (non-replicated). Persist the per-caller
  // code_verifier and state in actor state beside `xAuthByUser`.
  // See https://developer.x.com/en/docs/authentication/oauth-2-0/authorization-code
  // ------------------------------------------------------------------

  public func startAuthorize(clientId : Text, redirectUri : Text, caller : Principal) : async* Text {
    // 1. Generate a code_verifier (43-128 chars, [A-Za-z0-9-._~]) and a state token.
    // 2. Persist both under `caller`.
    // 3. Return: https://x.com/i/oauth2/authorize?response_type=code
    //      &client_id={clientId}&redirect_uri={redirectUri}
    //      &scope=tweet.read+tweet.write+users.read+offline.access
    //      &state={state}&code_challenge={base64url(sha256(verifier))}
    //      &code_challenge_method=S256
    let _ = clientId;
    let _ = redirectUri;
    let _ = caller;
    Runtime.trap("startAuthorize: implement the OAuth 2.0 PKCE handshake");
  };

  public func exchangeCode(clientId : Text, code : Text, redirectUri : Text, caller : Principal) : async* XAuth {
    // Verify `state`, then POST https://api.x.com/2/oauth2/token
    //   (application/x-www-form-urlencoded): grant_type=authorization_code
    //   & code & redirect_uri & client_id & code_verifier (persisted for `caller`).
    // Return XAuth with expires_at = Time.now() + expires_in * 1_000_000_000.
    let _ = clientId;
    let _ = code;
    let _ = redirectUri;
    let _ = caller;
    Runtime.trap("exchangeCode: implement the OAuth 2.0 token exchange");
  };

  public func ensureFreshToken(clientId : Text, auth : XAuth) : async* XAuth {
    // If Time.now() + 60s < auth.expires_at, return auth unchanged. Otherwise POST
    // https://api.x.com/2/oauth2/token with grant_type=refresh_token
    //   & refresh_token={auth.refresh_token} & client_id={clientId}
    // and return the NEW pair: X rotates the refresh token on every refresh.
    let _ = clientId;
    let _ = auth;
    Runtime.trap("ensureFreshToken: implement the refresh");
  };
};
```

### Invariants

- **Admin sets the Client ID, never a token.** No `getXClientId`:
  `isXClientIdConfigured : Bool` is its only outward read.
- **Tokens never leave the canister.** Read `xAuthByUser` only through
  `Map.get(..., caller)`; never add a function returning `XAuth`, a token or
  any prefix of one, and never log one. A leaked bearer is a per-user account
  compromise.
- **Three traps, three messages:** "X is not configured" (admin task),
  "Connect your X account first" (start `startXOAuth`), "Sign in to …" (login).
- **Reads use a connected user's token.** A feed that visitors without an X
  connection see must be fetched by a connected user (often the admin) and kept
  in actor state; refresh it on demand rather than on every page view.

**Other Client ID variants.** For a multi-tenant app whose tenants must not
share rate-limit quota, store `Map<Principal, Text>` of per-user Client IDs set
by any signed-in user (`setMyXClientId`, `isMyXClientIdConfigured`) instead of
the admin slot; for a fallback, keep both and look up the user's own ID before
the admin default. Use them only when the spec asks.

## Calls are non-replicated by default

Every `x-client` call is an `http_request` on the IC. The package ships
`is_replicated = ?false` in `defaultConfig`: posting mutates state, and X's
rate-limit headers and timestamps vary per request, so a *replicated* outcall
(every subnet node issuing the request, ~13× cycles) would post duplicates, send
the bearer over every node's connection, and fail consensus. Keep the default;
never override it to `null` or `?true`.

## Optional fields: leave them `null`

`x-client` strips null-valued optional fields from the outbound JSON, so
`/2/tweets` sees only the fields you set. `TweetCreateRequest.init {}` defaults
every optional to `null`; rebind the ones you need (`text_` serialises to the
JSON key `"text"`). If you set `poll`, `reply`, `geo`, `media`, or
`edit_options`, X enforces that sub-object's required fields:

- `poll` — `options` (≥ 2) and `duration_minutes`.
- `reply` — `in_reply_to_tweet_id`.
- `media` — `media_ids` (must be pre-uploaded).
- `geo` — `place_id`.

Every field of a response model is optional too: match on `?` instead of
assuming `data`, `id` or `text_` is present.

## Read parameters

Read operations take every query parameter positionally. Pass `""` for an
unused string, `0` for an unused count, `null` for an unused enum and `[]` for
the field lists; they are left out of the URL. Search queries use X's
[search syntax](https://developer.x.com/en/docs/x-api/tweets/search/integrate/build-a-query)
(`@handle`, `#tag`, `from:handle`, `-is:retweet`). `getUsersMentions` and
`getUsersPosts` take a numeric user id, not a handle: resolve it once with
`UsersApi.getUsersByUsername`.

## Cycles

Leave `cycles` unset (`null`): each call attaches the fee the IC charges for
that request. `?n` attaches exactly `n` cycles and fails on a subnet where the
canister holds fewer.

## Rate limits

Free tier: 1500 posts/month, 500 reads/month per app. Back off on HTTP 429;
never silently retry a post (a retry may duplicate the tweet). Cache read
results in actor state instead of calling X on every render.

# Frontend

Every X build ships these surfaces; the frontend never holds tokens and never
calls X itself.

1. **Sign-in.** All X routes sit behind
   [`extension-authorization`](../extension-authorization/SKILL.md)'s auth
   guard (`useInternetIdentity` + redirect when `!isAuthenticated`).
2. **Admin settings page** — `/settings/x`, admin-gated (hide the nav link
   from non-admins with `isCallerAdmin`): a password input bound to
   `setXClientId(id)`, cleared on success, and "Configured" / "Not configured"
   from `isXClientIdConfigured()`. Never display the Client ID.
3. **Connect page** — `/connect/x`, any signed-in user: "Connect X" calls
   `startXOAuth(window.location.origin + '/connect/x')` and redirects to the
   returned URL; on return, read `?code=` and call
   `completeXOAuth(code, redirectUri)` with the same `redirectUri`. Status from
   `isMyXConnected()`; optional "Disconnect X" bound to `disconnectMyX()`. To
   show "Connected as @…", add a backend endpoint that calls
   `UsersApi.getUsersMe`; never decode the bearer in JS.
4. **Empty-state nudge** — where the app posts or reads and
   `isMyXConnected()` is `false`, link to `/connect/x` instead of letting the
   call trap.

The canister generates and verifies the OAuth `state`; the frontend never mints
or echoes it. No `localStorage`, `IndexedDB` or cookies for X data: the browser
sees only `Bool` status flags, redirect URLs, and the posts the backend returns.

## Related

- [`x-client` on mops](https://mops.one/x-client) — connector source.
- [OAuth 2.0 Authorization Code with PKCE (X docs)](https://developer.x.com/en/docs/authentication/oauth-2-0/authorization-code).
- [`/2/tweets` reference](https://developer.x.com/en/docs/x-api/tweets/manage-tweets/api-reference/post-tweets) and [recent search reference](https://developer.x.com/en/docs/x-api/tweets/search/api-reference/get-tweets-search-recent).
- [extension-authorization](../extension-authorization/SKILL.md) — required prerequisite.
