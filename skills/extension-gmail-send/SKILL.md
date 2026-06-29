---
name: connector-googlemail
description: >-
  Use the `googlemail-client` mops package whenever the user asks the
  canister to send email, compose a draft, list or read Gmail messages, or
  fetch the authenticated user's Gmail profile.  The package wraps the Gmail
  REST API v1 at `https://gmail.googleapis.com` via outbound HTTPS calls.
version: 0.1.3
compatibility:
  mops:
    googlemail-client: "~0.1.3"
---

# googlemail-client

Motoko bindings for the [Gmail API v1](https://developers.google.com/gmail/api),
generated from Google's official OpenAPI spec.

Send-focused PoC surface: `gmail_users_messages_send`,
`gmail_users_drafts_{create,send,get,list}`, `gmail_users_messages_{get,list}`,
`gmail_users_getProfile`. All 8 operations live in `Apis/UsersApi.mo`.

## Trigger phrases

Reach for this skill on any request mentioning: send email, send message,
compose email, Gmail, draft, inbox, mailbox, "email the user", "notify via
email", "forward results by email", "send a notification email".

## How Gmail authentication works (read before wiring)

Gmail uses **OAuth 2.0 Authorization Code** flow — there is no static API key.
The canister never mints a token on its own; the user completes an OAuth dance
off-chain and passes in the resulting **Bearer access token** at call time.

Token lifetime: **1 hour** by default (Google's access tokens).  After expiry
the API returns HTTP 401.  The refresh token must be exchanged off-chain too —
the canister cannot call Google's token endpoint (that would expose the client
secret on-chain).  Surface a `#Err("auth_expired")` result and ask the caller
to re-authenticate.

Required OAuth 2.0 scope for `messages.send`: `https://www.googleapis.com/auth/gmail.send`.
For read access add: `https://www.googleapis.com/auth/gmail.readonly`.

## Usage

```motoko
import { gmail_users_messages_send; gmail_users_getProfile;
         gmail_users_drafts_create; gmail_users_drafts_send }
  "mo:googlemail-client/Apis/UsersApi";
import { Message; type Message } "mo:googlemail-client/Models/Message";
import { Draft; type Draft } "mo:googlemail-client/Models/Draft";
import { defaultConfig } "mo:googlemail-client/Config";
import Text "mo:core/Text";  // Text.encodeUtf8: build the raw RFC 2822 Blob

// Shared cfg — swap in the caller's short-lived bearer token.
let cfg = {
  defaultConfig with
    auth               = ?#bearer "<off-chain OAuth2 access token>";
    max_response_bytes = ?500_000;
    is_replicated      = ?false; // non-replicated: required for sends (see Notes); reads too
};

// Send a message. `raw` is the PLAIN RFC 2822 message as a Blob — the client
// base64-encodes it for the Gmail API; do NOT base64-encode it yourself.
let mime : Text = "From: me\r\nTo: friend@example.com\r\nSubject: Hi\r\n\r\nHello!";
let outMsg = Message.init {};   // all-null base, then layer fields:
let envelope : Message = { outMsg with raw = ?Text.encodeUtf8(mime) };
let result = await* gmail_users_messages_send(cfg,
  "me",         // userId: "me" = authenticated user
  #_1_,         // $.xgafv — use #_1_ (v1) for all calls
  "",           // accessToken — leave "" when auth = ?#bearer above
  #json,        // alt
  "", "", "", "", true, "", "", "",   // callback/fields/key/oauthToken/prettyPrint/quotaUser/uploadProtocol/uploadType
  envelope
);

// Get the authenticated user's email address
let profile = await* gmail_users_getProfile(cfg, "me",
  #_1_, "", #json, "", "", "", "", true, "", "", "");
let ?email = profile.emailAddress else return #Err("no email");
```

## Notes

- **Use `is_replicated = ?false` (non-replicated) for sends** (`gmail_users_messages_send`,
  `gmail_users_drafts_send`). These outcalls are **non-idempotent** and Gmail's response
  is **non-deterministic** (unique message `id`, per-request `Date` header). In
  *replicated* mode (`null`) every subnet replica issues the request — so the email is
  sent **once per replica** (duplicates) **and** the differing responses fail IC
  consensus (*"No consensus could be reached. Replicas had different responses"*).
  Non-replicated has a single node perform exactly one send. Reads
  (`gmail_users_messages_list`, `gmail_users_messages_get`, `gmail_users_getProfile`)
  also use `?false` (one node, ~13× cheaper).
- The `$.xgafv` parameter (version discriminator) should always be `#_1_` for
  Gmail API v1 calls.  The `alt` parameter should always be `#json`.
- All optional string parameters (`callback`, `fields`, `key`, `oauthToken`,
  `quotaUser`, `uploadProtocol`, `uploadType`) accept `""` to omit them;
  `prettyPrint` can be `false`.
- `userId` = `"me"` refers to the authenticated user. Explicit email addresses
  also work but require the `https://mail.google.com/` scope.
- Messages must be in RFC 2822 format, passed as a **plain `Blob`** in the `raw`
  field (e.g. `?Text.encodeUtf8(mime)`). The client base64-encodes `raw` for the
  API — do **not** base64-encode it yourself (that double-encodes and Gmail
  rejects it). The `Message.payload` / `MessagePart` fields are for parsed read
  responses — don't try to build them for sending.
- Google returns HTTP 429 on rate-limit (quota exceeded).  Surface the error to
  the caller; never silently retry inside the canister — a send retry may
  deliver duplicates.
- Access tokens expire in 1 hour.  On 401, surface `#Err("auth_expired")` so
  the caller can re-authenticate off-chain and retry with a fresh token.
- `Draft.message` holds a `Message`; `gmail_users_drafts_create` builds a draft
  server-side. Use `gmail_users_drafts_send` to send a draft by its `id`.
- `max_response_bytes`: Gmail message reads can be large.  500 KB covers typical
  messages; bump to 2 MB for messages with large payloads (Gmail API's max
  response is bounded by the API, but set conservatively for cycle budgets).
- Cycle budget: `defaultConfig.cycles = 30_000_000_000` (30B).  On the IC,
  outbound HTTPS calls cost ~10–15B cycles for a typical send.  Adjust if
  you see `InsufficientCycles` errors.
