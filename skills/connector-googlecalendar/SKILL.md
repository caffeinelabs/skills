---
name: connector-googlecalendar
description: >-
  Use the `googlecalendar-client` mops package whenever the user asks the
  canister to read, create, update, or delete Google Calendar events,
  list calendars, check free/busy availability, or manage calendar ACLs
  and settings.  The package wraps the Google Calendar API v3 at
  `https://www.googleapis.com/calendar/v3` via outbound HTTPS calls.
version: 0.1.1
compatibility:
  mops:
    googlecalendar-client: "~0.1.1"
---

# googlecalendar-client

Motoko bindings for the [Google Calendar API v3](https://developers.google.com/calendar/api),
generated from Google's official OpenAPI spec.

Full surface — 37 operations across 8 tags:
`Apis/EventsApi.mo` (list/get/insert/update/patch/delete/move/quickAdd/import/instances/watch),
`Apis/CalendarsApi.mo`, `Apis/CalendarListApi.mo`, `Apis/AclApi.mo`,
`Apis/FreebusyApi.mo`, `Apis/SettingsApi.mo`, `Apis/ColorsApi.mo`,
`Apis/ChannelsApi.mo`. Function names are prefixed `calendar_<tag>_<op>`
(e.g. `calendar_events_insert`, `calendar_events_list`, `calendar_freebusy_query`).

## Trigger phrases

Reach for this skill on any request mentioning: schedule a meeting, create an
event, add to calendar, book a slot, check availability, free/busy, list my
events, upcoming events, agenda, reschedule, cancel a meeting, invite
attendees, "put it on the calendar", "when am I free".

## How Google Calendar authentication works (read before wiring)

Google Calendar uses **OAuth 2.0 Authorization Code** flow — there is no static
API key.  Each end-user authorises their own calendar; the app exchanges the
authorization code for a short-lived **Bearer access token** (~1 hour) and
passes that token to the client at call time.  On expiry the API returns HTTP
401 — surface an `#Err("auth_expired")` result and re-authenticate.

**The token exchange is an on-chain outcall** to Google's token endpoint and
requires the Google **Client Secret**.  Two hazards to design around:

- **`is_replicated = ?false` on the exchange too.**  The token response is
  non-deterministic (fresh token + expiry per call), so a *replicated* exchange
  duplicates across ~13 replicas and fails IC consensus — the same failure mode
  as a replicated write.
- **The Client Secret leaks with exported source.**  It is embedded in the
  canister source, and Caffeine lets users export their app to a downloaded
  `.zip` *or a public GitHub repo* — the secret rides along in both.  Treat it
  as **leakable**: scope it minimally and rotate it if the source is ever
  exported or shared.

Persist the per-user refresh/session token across upgrades (stable memory) so a
redeploy doesn't force every user to re-authenticate.

OAuth 2.0 scopes: `https://www.googleapis.com/auth/calendar` (read/write),
`https://www.googleapis.com/auth/calendar.events` (events only), or the
`.readonly` variants for read-only access.

## Usage

```motoko
import { calendar_events_insert; calendar_events_list; calendar_events_get;
         calendar_events_delete }
  "mo:googlecalendar-client/Apis/EventsApi";
import { Event; type Event } "mo:googlecalendar-client/Models/Event";
import { EventDateTime } "mo:googlecalendar-client/Models/EventDateTime";
import { defaultConfig } "mo:googlecalendar-client/Config";

// Shared cfg — swap in the caller's short-lived bearer token.
let cfg = {
  defaultConfig with
    auth               = ?#bearer "<off-chain OAuth2 access token>";
    max_response_bytes = ?500_000;
    is_replicated      = ?false; // non-replicated: required for writes (see Notes); reads too
};

// Create an event.  Build it from the all-null base, then layer fields:
let start : EventDateTime = { EventDateTime.init {} with
  dateTime = ?"2026-07-10T15:00:00-07:00"; timeZone = ?"America/Los_Angeles" };
let end : EventDateTime = { EventDateTime.init {} with
  dateTime = ?"2026-07-10T16:00:00-07:00"; timeZone = ?"America/Los_Angeles" };
let ev : Event = { Event.init {} with
  summary = ?"Design review"; location = ?"Room 4"; start = ?start; end = ?end };

let created = await* calendar_events_insert(cfg,
  "primary",    // calendarId: "primary" = the authenticated user's default calendar
  #json,        // alt — always #json
  "", "", "",   // fields / key / oauthToken (leave "" when auth = ?#bearer above)
  true,         // prettyPrint
  "", "",       // quotaUser / userIp
  0, 0,         // conferenceDataVersion / maxAttendees (0 = omit)
  true,         // sendNotifications
  #all,         // sendUpdates — #all | #externalonly | #none_
  false,        // supportsAttachments
  ev
);

// List upcoming events (RFC 3339 timeMin).  Most list params accept "" / 0 / false to omit.
let upcoming = await* calendar_events_list(cfg, "primary", #json,
  "", "", "", true, "", "",              // fields/key/oauthToken/prettyPrint/quotaUser/userIp
  false, [], "", 0, 10,                  // alwaysIncludeEmail/eventTypes/iCalUID/maxAttendees/maxResults
  #startTime, "", [], "", [],            // orderBy/pageToken/privateExtendedProperty/q/sharedExtendedProperty
  false, false, true, "",                // showDeleted/showHiddenInvitations/singleEvents/syncToken
  "", "2026-07-01T00:00:00Z", "", "");   // timeMax/timeMin/timeZone/updatedMin
```

## Notes

- **Use `is_replicated = ?false` (non-replicated) for writes** (`calendar_events_insert`,
  `calendar_events_update`, `calendar_events_patch`, `calendar_events_delete`,
  `calendar_events_move`, `calendar_events_quickAdd`, and the calendars/acl mutators).
  These outcalls are **non-idempotent** and Google's response is **non-deterministic**
  (fresh event `id`/`etag`, per-request timestamps). In *replicated* mode (`null`) every
  subnet replica issues the request — so the event is created **once per replica**
  (duplicates) **and** the differing responses fail IC consensus (*"No consensus could
  be reached. Replicas had different responses"*). Non-replicated has a single node
  perform exactly one write. Reads (`calendar_events_list`, `calendar_events_get`,
  `calendar_freebusy_query`, `calendar_calendars_get`) also use `?false` (~13× cheaper).
- The `alt` parameter should always be `#json`.
- `calendarId` = `"primary"` refers to the authenticated user's default calendar.
  Named/shared calendars use their calendar-ID (an email-like address).
- Timestamps are **RFC 3339** strings (`2026-07-10T15:00:00-07:00`).  For all-day
  events set `EventDateTime.date` (`YYYY-MM-DD`) instead of `dateTime`.
- Build `Event` / `EventDateTime` with `init {}` then record-update the fields you
  need — all fields are optional (`?T`); leave the rest null.
- All optional string parameters (`fields`, `key`, `oauthToken`, `quotaUser`,
  `userIp`, `pageToken`, `q`, `timeMax`, `syncToken`, …) accept `""` to omit them;
  numeric params accept `0`, booleans `false`, arrays `[]`.
- PATCH operations (`calendar_events_patch`, `calendar_calendars_patch`,
  `calendar_acl_patch`, `calendar_calendarList_patch`) are available and forced
  non-replicated — PATCH outcalls are GA on the IC.
- Google returns HTTP 429 on rate-limit (quota exceeded).  Surface the error to
  the caller; never silently retry a write inside the canister — a retry may
  create a duplicate event.
- Access tokens expire in 1 hour.  On 401, surface `#Err("auth_expired")` so
  the caller can re-authenticate off-chain and retry with a fresh token.
- `max_response_bytes`: event lists can be large.  500 KB covers typical
  calendars; bump for very large listings.
- Cycle budget: `defaultConfig.cycles = 30_000_000_000` (30B).  On the IC,
  outbound HTTPS calls cost ~10–15B cycles for a typical request.  Adjust if
  you see `InsufficientCycles` errors.
