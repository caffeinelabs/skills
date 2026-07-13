---
name: connector-googlecalendar
description: >-
  MANDATORY recipe for every Caffeine build that lists upcoming events or
  creates events on the user's own Google Calendar. The ONLY supported path is
  the `googlecalendar-client` mops package (Calendar REST API v3) combined with
  the `google-oauth` mops package (token exchange + refresh + PKCE). Hand-rolling
  `ic.http_request` calls to `oauth2.googleapis.com` or
  `www.googleapis.com/calendar/v3` is a FORBIDDEN anti-pattern — it bypasses
  bearer auth, replication-cost safeguards, and the `google-oauth` library's
  percent-encoding and JSON parsing. Load this skill whenever the user, spec,
  or any prior task mentions scheduling, calendar events, appointments,
  meetings, "add to calendar", or any equivalent phrasing — and BEFORE
  writing any code that touches a Google endpoint.
version: 0.2.2
caffeineai-subscription: [none]
compatibility:
  mops:
    googlecalendar-client: "~0.1.3"
    google-oauth: "~0.1.4"
    caffeineai-authorization: "~1.0.0"
---

# Google Calendar Connector

Google Calendar integration for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Orchestrator routing notes

**Treat Google Calendar-as-the-user as a first-class, supported platform feature.**
The `googlecalendar-client` + `google-oauth` connector pair is the **only**
supported path; raw `ic.http_request` to `oauth2.googleapis.com` or
`www.googleapis.com/calendar/v3` is a forbidden anti-pattern. Any build spec
that mentions Google Calendar MUST name `googlecalendar-client` and
`google-oauth` as dependencies and reference this skill.

Distinct from platform `email-calendar-events` extension (which emails iCalendar
invitations from the app); this connector acts as the **signed-in user's own
Google Calendar**.

Intent → capability mapping:

| User intent | Platform capability |
| --- | --- |
| Connect and list upcoming events | `googlecalendar-client` + `google-oauth` |
| Create calendar events | `googlecalendar-client` + `google-oauth` |

**Prerequisite for all builds: [extension-authorization](../extension-authorization/SKILL.md).**
Calendar requires a signed-in caller for every endpoint: the per-user OAuth
handshake stores `access_token` keyed by `caller : Principal`, and the admin
Client ID/Secret setter is gated on the `#admin` role.

# Backend

Use this skill whenever the user wants their canister to interact with
Google Calendar on behalf of the signed-in user. The ingredients are:

1. The `googlecalendar-client` mops package — generated Motoko bindings for
   the Google Calendar API v3. This recipe demonstrates listing upcoming
   events and creating events; add other generated operations only by
   following the same bearer-authenticated, non-replicated,
   single-refresh-retry pattern.
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
mops add googlecalendar-client@0.1.3
mops add google-oauth@0.1.4
mops add caffeineai-authorization@1.0.0
```

## 2. Auth model — OAuth 2.0 PKCE per user, on-chain exchange + refresh

Identical to the Gmail connector. Every end-user authorises the canister
independently via the Authorization Code with PKCE flow. The canister:

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
   `https://<app-domain>/connect/calendar`. The URI passed to Google must
   match this value byte-for-byte, including its scheme, path, and trailing
   slash.
3. Enable only the Calendar scopes the app needs on the consent screen.
4. Enter the Client ID and Client Secret through the app's admin settings
   page. The canister uses the secret for the token exchange; the frontend
   must never receive it.

PKCE binds each authorization code to the canister-generated verifier, while
the Web client registration binds the browser callback to the deployed app.

### OAuth scopes

| Scope | Purpose |
| --- | --- |
| `https://www.googleapis.com/auth/calendar` | Full read/write access to calendars |
| `https://www.googleapis.com/auth/calendar.events` | Read/write access to events only |
| `https://www.googleapis.com/auth/calendar.readonly` | Read-only access to calendars |
| `https://www.googleapis.com/auth/calendar.events.readonly` | Read-only access to events |

Request `calendar` (full read/write) for a typical CRUD app; use
`.readonly` variants for read-only views.

### Storing tokens

The bearer **never leaves the canister**. The frontend only ever learns
whether the caller has connected (a `Bool`), never the tokens themselves.

- A `Map<Principal, CalendarConnection>` keyed by caller. Expose exactly the
  endpoints listed in §4 — `isMyCalendarConnected`, `startCalendarOAuth`,
  `completeCalendarOAuth`, `listUpcomingEvents`, `createEvent`,
  `disconnectMyCalendar` — every endpoint gated on `not caller.isAnonymous()`.
  **Do not add any endpoint that returns `access_token` / `refresh_token` /
  the full `CalendarConnection`.**
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
3. **Determinism.** Calendar write responses are non-deterministic (unique
   event `id`/`etag`, per-request timestamps). Replicated consensus would
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
- `src/backend/mixins/calendar-config.mo` — admin-gated Client ID + Secret.
- `src/backend/mixins/calendar-messaging.mo` — per-user OAuth + event ops.
- `src/backend/lib/calendar.mo` — `googlecalendar-client` + `google-oauth` glue.

```motoko filepath=src/backend/main.mo
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import MixinCalendarConfig "mixins/calendar-config";
import MixinCalendarMessaging "mixins/calendar-messaging";
import LibCalendar "lib/calendar";

actor {
  let accessControlState = AccessControl.initState();
  include MixinAuthorization(accessControlState, null);

  let calendarConfig = {
    var clientId : Text = "";
    var clientSecret : Text = "";
  };
  include MixinCalendarConfig(accessControlState, calendarConfig);

  let calendarConnections : Map.Map<Principal, LibCalendar.CalendarConnection> = Map.empty();
  let pendingCalendarFlows : Map.Map<Principal, LibCalendar.PendingOAuth> = Map.empty();
  include MixinCalendarMessaging(calendarConfig, calendarConnections, pendingCalendarFlows);
};
```

```motoko filepath=src/backend/mixins/calendar-config.mo
import AccessControl "mo:caffeineai-authorization/access-control";
import Runtime "mo:core/Runtime";

mixin (
  accessControlState : AccessControl.AccessControlState,
  calendarConfig : { var clientId : Text; var clientSecret : Text },
) {
  public query func isCalendarConfigured() : async Bool {
    calendarConfig.clientId.size() > 0;
  };

  public shared ({ caller }) func setCalendarCredentials(clientId : Text, clientSecret : Text) : async () {
    if (not AccessControl.hasPermission(accessControlState, caller, #admin)) {
      Runtime.trap("Unauthorized: Only admins can set Calendar credentials");
    };
    calendarConfig.clientId := clientId;
    calendarConfig.clientSecret := clientSecret;
  };
};
```

```motoko filepath=src/backend/mixins/calendar-messaging.mo
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import LibCalendar "../lib/calendar";

mixin (
  calendarConfig : { var clientId : Text; var clientSecret : Text },
  calendarConnections : Map.Map<Principal, LibCalendar.CalendarConnection>,
  pendingCalendarFlows : Map.Map<Principal, LibCalendar.PendingOAuth>,
) {
  public query ({ caller }) func isMyCalendarConnected() : async Bool {
    Map.containsKey(calendarConnections, Principal.compare, caller);
  };

  public shared ({ caller }) func startCalendarOAuth(redirectUri : Text) : async Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to connect Google Calendar");
    };
    if (calendarConfig.clientId.size() == 0) {
      Runtime.trap("Calendar is not configured (admin must set credentials)");
    };
    await* LibCalendar.startAuthorize(
      calendarConfig.clientId, redirectUri, caller, pendingCalendarFlows,
    );
  };

  public shared ({ caller }) func completeCalendarOAuth(code : Text, state : Text) : async () {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to connect Google Calendar");
    };
    if (calendarConfig.clientId.size() == 0) {
      Runtime.trap("Calendar is not configured");
    };
    let ?pending = Map.get(pendingCalendarFlows, Principal.compare, caller) else {
      Runtime.trap("No pending OAuth flow — call startCalendarOAuth first");
    };
    if (state != pending.state) {
      Runtime.trap("OAuth state did not match the pending Calendar flow");
    };
    Map.remove(pendingCalendarFlows, Principal.compare, caller);
    let connection = await* LibCalendar.exchangeCode(
      calendarConfig.clientId, calendarConfig.clientSecret, code,
      pending.redirectUri, pending.codeVerifier,
    );
    Map.add(calendarConnections, Principal.compare, caller, connection);
  };

  public shared ({ caller }) func listUpcomingEvents(
    timeMin : Text, maxResults : Nat,
  ) : async LibCalendar.EventSummaryList {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to list events");
    };
    let ?connection = Map.get(calendarConnections, Principal.compare, caller) else {
      Runtime.trap("Connect your Google Calendar first");
    };
    await* LibCalendar.listUpcomingEvents(
      calendarConfig.clientId, calendarConfig.clientSecret, connection, caller,
      calendarConnections, timeMin, maxResults,
    );
  };

  public shared ({ caller }) func createEvent(
    summary : Text, startDateTime : Text, endDateTime : Text,
  ) : async Text {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to create events");
    };
    let ?connection = Map.get(calendarConnections, Principal.compare, caller) else {
      Runtime.trap("Connect your Google Calendar first");
    };
    await* LibCalendar.createEvent(
      calendarConfig.clientId, calendarConfig.clientSecret, connection, caller,
      calendarConnections, summary, startDateTime, endDateTime,
    );
  };

  public shared ({ caller }) func disconnectMyCalendar() : async () {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to disconnect");
    };
    Map.remove(calendarConnections, Principal.compare, caller);
  };
};
```

```motoko filepath=src/backend/lib/calendar.mo
import Array "mo:core/Array";
import Map "mo:core/Map";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import OAuth "mo:google-oauth/OAuth";
import { calendar_events_list; calendar_events_insert } "mo:googlecalendar-client/Apis/EventsApi";
import { type Event; JSON = Event } "mo:googlecalendar-client/Models/Event";
import { type EventDateTime; JSON = EventDateTime } "mo:googlecalendar-client/Models/EventDateTime";
import { type Events; JSON = Events } "mo:googlecalendar-client/Models/Events";
import { defaultConfig; type Config } "mo:googlecalendar-client/Config";

module {
  public type CalendarConnection = {
    accessToken : Text;
    refreshToken : Text;
  };

  public type PendingOAuth = {
    codeVerifier : Text;
    redirectUri : Text;
    state : Text;
  };

  public type EventSummary = {
    id : Text;
    summary : Text;
    start : Text;
    end : Text;
  };

  public type EventSummaryList = [EventSummary];

  let SCOPES : Text = "https://www.googleapis.com/auth/calendar";

  func configForToken(token : Text) : Config {
    {
      defaultConfig with
      auth = ?#bearer(token);
      is_replicated = ?false;
      max_response_bytes = ?Nat64.fromNat(2_000_000);
    };
  };

  func refreshIfNeeded(
    clientId : Text, clientSecret : Text, connection : CalendarConnection,
    caller : Principal, calendarConnections : Map.Map<Principal, CalendarConnection>,
    errorMsg : Text,
  ) : async* ?Text {
    if (not (errorMsg.contains(#text("401")) or errorMsg.contains(#text("Unauthorized")))) {
      Runtime.trap("Calendar API failed: " # errorMsg);
    };
    let refreshed = await OAuth.refreshAccessToken(clientId, clientSecret, connection.refreshToken);
    let newToken = accessTokenOf(refreshed, "Token refresh");
    Map.add(calendarConnections, Principal.compare, caller, {
      connection with accessToken = newToken;
    });
    ?newToken;
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
  ) : async* CalendarConnection {
    let tokens = await OAuth.exchangeAuthorizationCode(clientId, clientSecret, code, redirectUri, codeVerifier);
    let accessToken = accessTokenOf(tokens, "Token exchange");
    let refreshToken = switch (tokens.refreshToken) {
      case (?t) t;
      case null Runtime.trap("Token exchange failed: missing refresh_token");
    };
    { accessToken; refreshToken };
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

  public func listUpcomingEvents(
    clientId : Text, clientSecret : Text, connection : CalendarConnection,
    caller : Principal, calendarConnections : Map.Map<Principal, CalendarConnection>,
    timeMin : Text, maxResults : Nat,
  ) : async* EventSummaryList {
    if (timeMin.size() == 0) {
      Runtime.trap("timeMin must be an RFC 3339 timestamp");
    };
    let events : Events = try {
      await* calendar_events_list(
        configForToken(connection.accessToken), "primary", #json,
        "", "", "", true, "", "",
        false, [], "", 0, maxResults, #starttime,
        "", [], "", [], false, false, true, "",
        "", timeMin, "", "",
      );
    } catch e {
      let ?newToken = await* refreshIfNeeded(
        clientId, clientSecret, connection, caller, calendarConnections, e.message(),
      ) else Runtime.trap("Calendar API failed");
      await* calendar_events_list(
        configForToken(newToken), "primary", #json,
        "", "", "", true, "", "",
        false, [], "", 0, maxResults, #starttime,
        "", [], "", [], false, false, true, "",
        "", timeMin, "", "",
      );
    };
    eventSummariesOf(events);
  };

  public func createEvent(
    clientId : Text, clientSecret : Text, connection : CalendarConnection,
    caller : Principal, calendarConnections : Map.Map<Principal, CalendarConnection>,
    summary : Text, startDateTime : Text, endDateTime : Text,
  ) : async* Text {
    let start : EventDateTime = { EventDateTime.init {} with dateTime = ?startDateTime };
    let end : EventDateTime = { EventDateTime.init {} with dateTime = ?endDateTime };
    let event : Event = { Event.init {} with
      summary = ?summary;
      start = ?start;
      end = ?end;
    };
    let created : Event = try {
      await* calendar_events_insert(
        configForToken(connection.accessToken), "primary", #json,
        "", "", "", true, "", "",
        0, 0, true, #all, false, event,
      );
    } catch e {
      let ?newToken = await* refreshIfNeeded(
        clientId, clientSecret, connection, caller, calendarConnections, e.message(),
      ) else Runtime.trap("Calendar API failed");
      await* calendar_events_insert(
        configForToken(newToken), "primary", #json,
        "", "", "", true, "", "",
        0, 0, true, #all, false, event,
      );
    };
    switch (created.id) {
      case (?id) id;
      case null "";
    };
  };

  func eventSummariesOf(events : Events) : EventSummaryList {
    let items = switch (events.items) {
      case (?items) items;
      case null [];
    };
    Array.map<Event, EventSummary>(items, func(e : Event) : EventSummary = {
      id = switch (e.id) { case (?id) id; case null "" };
      summary = switch (e.summary) { case (?s) s; case null "(no title)" };
      start = switch (e.start) {
        case (?dt) switch (dt.dateTime) { case (?t) t; case null switch (dt.date) { case (?d) d; case null "" } };
        case null "";
      };
      end = switch (e.end) {
        case (?dt) switch (dt.dateTime) { case (?t) t; case null switch (dt.date) { case (?d) d; case null "" } };
        case null "";
      };
    });
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

### `googlecalendar-client` (Calendar REST API v3)

The canonical actor above intentionally implements only upcoming-event listing
and event creation. For another generated operation, keep bearer
authentication and `is_replicated = ?false`, then apply the same
single-refresh-retry pattern as `refreshIfNeeded`.

The generated package also exposes:

| Function | Module | Purpose |
| --- | --- | --- |
| `calendar_events_list` | EventsApi | List events on a calendar |
| `calendar_events_get` | EventsApi | Get an event by id |
| `calendar_events_insert` | EventsApi | Create an event |
| `calendar_events_update` | EventsApi | Update an event (PUT) |
| `calendar_events_patch` | EventsApi | Patch an event (PATCH) |
| `calendar_events_delete` | EventsApi | Delete an event |
| `calendar_events_move` | EventsApi | Move an event to another calendar |
| `calendar_events_quickAdd` | EventsApi | Create event from text ("Lunch at noon") |
| `calendar_events_instances` | EventsApi | List instances of a recurring event |
| `calendar_freebusy_query` | FreebusyApi | Check free/busy across calendars |
| `calendar_calendarList_list` | CalendarListApi | List user's calendars |
| `calendar_calendarList_get` | CalendarListApi | Get a calendar list entry |
| `calendar_calendars_get` | CalendarsApi | Get calendar metadata |
| `calendar_calendars_insert` | CalendarsApi | Create a secondary calendar |

## 6. Cycles and response sizes

The `google-oauth` library uses `Call.httpRequest` from `mo:ic/Call`, which
auto-computes and attaches the exact required cycles via the
`ic0.cost_http_request` system API. No manual cycle budgeting is needed
for token exchange or refresh calls.

For `googlecalendar-client` calls, `defaultConfig.cycles = 30_000_000_000`
(30B). A typical list/insert costs ~10–15B cycles. Set
`max_response_bytes = ?2_000_000` for event list reads that may include
large payloads.

## 7. Things that will bite you

- **`is_replicated = ?false`** — see §3. Non-negotiable.
- **Google refresh tokens do NOT rotate.** Unlike X/Twitter, Google does
  not issue a new `refresh_token` on each refresh. Keep the original
  `refresh_token` and only persist the new `access_token`.
- **Access tokens expire in 1 hour.** The `refreshIfNeeded` helper catches
  HTTP 401, silently refreshes via `google-oauth.refreshAccessToken`, and
  retries once. If the refresh also fails, surface "re-connect your account".
- **Callback URI exact-match.** Every character (trailing slash, query
  string, port) must match between the authorize URL and the redirect.
  Google returns `redirect_uri_mismatch` otherwise. Always use
  `window.location.origin + window.location.pathname` for `redirectUri` and
  register that exact URI on the Google Web client.
- **RFC 3339 timestamps.** Calendar uses RFC 3339 strings
  (`2026-07-10T15:00:00-07:00`). For all-day events set
  `EventDateTime.date` (`YYYY-MM-DD`) instead of `dateTime`.
- **`calendarId = "primary"`** refers to the authenticated user's default
  calendar. Named/shared calendars use their calendar-ID (an email-like
  address).
- **HTTP 429 rate-limit.** Surface the error to the caller; never
  silently retry a write inside the canister — a retry may create a
  duplicate event.
- **Don't expose the access token.** `calendarConnections` is read only by
  `Map.get(calendarConnections, ..., caller)` inside API calls. No
  `getMyCalendarConnection`, no `getMyAccessToken`, no iterator. A leaked
  bearer is a per-user account compromise.
- **`alt = #json`** for all Calendar API v3 calls. Leave optional string
  parameters `""` and `prettyPrint = false`.
- **Build `Event` / `EventDateTime` with `init {}` then record-update**
  the fields you need — all fields are optional (`?T`); leave the rest null.
- **PATCH/PUT/DELETE are forced non-replicated** in the generated client
  (the `googlecalendar-client` sets `is_replicated = ?false` on these
  methods automatically). For GET/POST, set it explicitly in your `Config`.

# Frontend

Every build using this skill must ship:

1. **A login flow — required.** Calendar cannot work without a non-anonymous
   caller; the per-user OAuth handshake stores tokens keyed by
   `caller : Principal`, and the admin credential setter gates on
   `#admin`. The login flow comes from
   [`extension-authorization`](../extension-authorization/SKILL.md):
   `useInternetIdentity`, login/logout buttons, the `useActor` plumbing
   that injects the authenticated identity into every backend call.

2. **An admin settings page** — `/settings/calendar` (admin-gated):
   - Two password-inputs bound to `setCalendarCredentials(clientId, clientSecret)`.
     Submit on enter; clear inputs on success.
   - Status indicator driven by `isCalendarConfigured()` (returns `Bool`).
     Show "Configured" / "Not configured" — never display the credentials.
   - Hide from non-admins via
     [`extension-authorization`](../extension-authorization/SKILL.md)'s
     `isCallerAdmin` query — non-admins should not see the link in the nav.

3. **A "Connect Calendar" page** — `/connect/calendar` (any signed-in user):
   - "Connect Google Calendar" button bound to
     `startCalendarOAuth(window.location.origin + window.location.pathname)`.
     Redirect the browser to the URL returned by the canister. Register this
     exact URI in the Google Cloud Console first.
   - On the return leg, read `error`, `code`, and `state` from
     `URLSearchParams`. If `error` is present, show the failed/declined
     connection state and do not call the canister. Only when both `code`
     and `state` are present, call `completeCalendarOAuth(code, state)`.
   - After either terminal path, call `history.replaceState` to remove the
     OAuth query parameters. This prevents a page refresh from reusing a
     one-time authorization code.
   - Status driven by `isMyCalendarConnected()` (returns `Bool`).
   - Optional "Disconnect Calendar" button bound to `disconnectMyCalendar()`.

4. **Calendar UI** — the main page shows upcoming events. Pass the current
   time as the RFC 3339 `timeMin` value:
   `listUpcomingEvents(new Date().toISOString(), 10)`. This is required when
   using `singleEvents = true` and `orderBy = startTime`. Also include a
   "create event" form. `datetime-local` values have no offset, so convert
   each browser-local value to an RFC 3339 instant before calling the actor:
   `createEvent(summary, new Date(startInput).toISOString(),
   new Date(endInput).toISOString())`.
   When `isMyCalendarConnected()` is `false`, render an inline
   "Connect Google Calendar" link to `/connect/calendar`.

Suggested route layout:

```
/                   →  Main UI (upcoming events + create form)
/settings/calendar  →  Admin credential config (admin-only)
/connect/calendar   →  Per-user OAuth handshake (any signed-in user)
```

## Common to all variants

- **Sign-in is required** for every Calendar-related route. Wire the
  `/settings/...` and `/connect/calendar` routes through
  [`extension-authorization`](../extension-authorization/SKILL.md)'s
  auth guard (`useInternetIdentity` + redirect when `!isAuthenticated`).
- **The frontend never persists tokens.** No `localStorage`, no
  `IndexedDB`, no cookies — the canister mediates everything. The browser
  only ever sees `Bool` status flags and the OAuth redirect URLs.
- **The OAuth `state` parameter is canister-generated and validated.** The
  canister stores a random nonce with the pending verifier and callback URI.
  The frontend must pass both `code` and `state` to `completeCalendarOAuth`;
  it never creates or modifies either value.
- **The calendar UI is trivial:** a list of upcoming events, a create-event
  form with summary + start/end datetime inputs. No client-side Google SDK,
  no token handling, no JSON serialization — the canister is the Calendar client.

## Related

- [`mops add googlecalendar-client@0.1.3`](https://mops.one/googlecalendar-client) — Calendar REST API v3 bindings.
- [`mops add google-oauth@0.1.4`](https://mops.one/google-oauth) — Google OAuth 2.0 library (token exchange, refresh, PKCE).
- [Google OAuth 2.0 for Web Server Applications](https://developers.google.com/identity/protocols/oauth2/web-server) — Web-client redirect URI and authorization-code flow reference.
- [Google Calendar API v3 reference](https://developers.google.com/calendar/api/v3/reference) — what `googlecalendar-client` wraps.
- [RFC 7636 — Proof Key for Code Exchange](https://datatracker.ietf.org/doc/html/rfc7636) — PKCE spec.
- [extension-authorization](../extension-authorization/SKILL.md) — **required prerequisite**. Provides Internet Identity login, `useInternetIdentity` / `useActor` frontend plumbing, and the `#admin` role gate.
- [connector-googlemail](../connector-googlemail/SKILL.md) — sister connector using the same `google-oauth` library for Gmail.
