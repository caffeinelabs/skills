---
name: extension-inference
description: >-
  MANDATORY recipe for every Caffeine build that calls an LLM, chatbot,
  GPT, or ChatGPT **on Caffeine Inference** (no user-pasted OpenAI key).
  The ONLY supported path is the `caffeineai-inference-client` mops package
  with `Config.fromEnv<system>()`, which hands the canister a ready-to-use
  authenticated config — the app never asks for, stores, or returns a key.
  For interactive features the browser can call the API itself with a
  short-lived key that `Ephemeral.Broker` mints. Hand-rolling
  `ic.http_request` to `inference.caffeine.ai` (or `api.openai.com`) is a
  FORBIDDEN anti-pattern. Load this skill whenever
  the user, spec, or any prior task wants an LLM in a Caffeine app — and
  BEFORE writing any code that talks to an LLM host. Use `extension-openai`
  only when the spec explicitly requires a user- or admin-pasted `sk-...`
  key against `api.openai.com`.
version: 0.2.1
compatibility:
  mops:
    caffeineai-inference-client: "~0.4.0"
caffeineai-subscription: [none]
---

# Caffeine Inference
LLM extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Orchestrator routing notes

Treat “use an LLM / GPT / chatbot / summarise with AI” as a first-class
platform feature. The default path is **Caffeine Inference**: an
OpenAI-compatible chat endpoint that Caffeine hosts, authenticates, and bills
for the app. The canister gets its credentials from the platform at runtime;
nobody pastes an API key, and the app never stores or returns its own key.
The frontend-direct path gives the browser short-lived child keys instead.

| User intent | Capability |
| --- | --- |
| Chat / summarise / classify with an LLM in a Caffeine app | `caffeineai-inference-client` `ChatApi.createChatCompletion` via this skill |
| Chat, lookups, or translation where the user waits for the reply | The frontend-direct path of this skill: the browser calls the API with a key from `Ephemeral.Broker` |
| Call `api.openai.com` with a user-pasted `sk-...` | [`extension-openai`](../extension-openai/SKILL.md) only |

Do **not** load `extension-openai` for a normal Caffeine-app LLM. Do **not**
ask the user for an OpenAI API key. Do **not** add `setApiKey` endpoints, a
key-settings page, or a model picker.

## Choose a path

| | Backend path | Frontend-direct path |
| --- | --- | --- |
| Who calls the API | The canister, as an HTTPS outcall | The browser, with a 3-hour key the canister mints |
| Latency | An update call plus an outcall: seconds, all at once | No update call; the reply streams as the model writes it |
| Cycles per call | One outcall | None. Only key mints are outcalls |
| Prompt | Hidden in the canister, so the backend can trust the result | Visible and editable in the browser |
| Result | The canister has it | The browser has it and saves it in the background |

- Use the frontend-direct path for features a signed-in user waits on:
  chat, word lookups, translation, suggestions.
- Use the backend path when the backend must trust or keep the result
  (grading, moderation, anything other users see), when no user is
  waiting (timers), and in apps without sign-in.
- An app can use both, one per feature.

Never mint keys for anonymous callers: a key leaves the canister, so anyone
could spend the app's credits with it. Check the caller in the mint method,
with the app's own access rule.

- In an app with sign-in, also run that rule in every backend chat method.
- An app without sign-in uses only the backend path, and its chat methods
  take any caller.

# Backend

## 1. Add `caffeineai-inference-client` to `mops.toml`

```bash
mops add caffeineai-inference-client@0.4.1
```

Requires Mops ≥ 2.13. **Minimum version:** `caffeineai-inference-client ≥ 0.4.0`.

## 2. Config comes from the platform

`Config.fromEnv<system>()` returns a complete `Config` — endpoint, bearer, and
`is_replicated = ?false` — from the credentials the platform provisions for the
app. There is no key to collect and nothing to configure.

- Call `fromEnv<system>()` **inside** the `shared` method, or in a
  `<system>`-parameterised helper, on **every** request. A module-level
  `let config = fromEnv` will not compile, and a cached `Config` can go stale
  when the platform rotates credentials on a running canister.
- It traps when the app has no inference credentials. Let that error reach
  the caller; hiding it makes a failed AI call look like a working feature:
  - Never pre-check `CAFFEINE_INFERENCE_API_KEY` (or any other environment
    variable) and never guard `fromEnv` with a check that skips the call.
  - Never turn a failed call into an empty success, such as an empty string,
    an empty list, or placeholder text. Trap or return the error so the
    frontend can show it and offer a retry.
  - Do not add a "configure AI" empty state or a key-input fallback.
- Never log the `Config`, never copy its `auth` into actor state, and never
  return it (or any part of it) from a `query` / `shared` function. The
  frontend-direct path returns a minted child key, never the app key.

## 3. `is_replicated = ?false` is REQUIRED

`fromEnv` already sets this. Do not override it to `?true` or `null`.

1. **Security.** A replicated outcall sends the bearer from every replica.
2. **Billing.** Replicated outcalls multiply inference spend by subnet size.
3. **Determinism.** LLM bodies are sampled; consensus would fail.

## 4. Canonical layout

Keep only the endpoints of the path each feature uses.

```motoko filepath=src/backend/main.mo
import Ephemeral "mo:caffeineai-inference-client/Ephemeral";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Inference "lib/inference";

actor {
  // A deploy revokes every minted key, so the broker's cache is transient.
  transient let inferenceKeys = Ephemeral.Broker(Ephemeral.defaultLimits);

  // Replace with the app's own rule, for example an approved-user check.
  func requireAiAccess(caller : Principal) {
    if (caller.isAnonymous()) Runtime.trap("Sign in to use AI features");
  };

  // Backend path
  public shared func chat(prompt : Text) : async Text {
    await* Inference.runChat<system>(prompt);
  };

  // Frontend-direct path
  public shared ({ caller }) func getInferenceCredentials() : async Ephemeral.Credentials {
    requireAiAccess(caller);
    await* inferenceKeys.grant<system>(caller);
  };
};
```

```motoko filepath=src/backend/lib/inference.mo
import { fromEnv } "mo:caffeineai-inference-client/Config";
import ChatApi "mo:caffeineai-inference-client/Apis/ChatApi";
import ChatCompletionRequest "mo:caffeineai-inference-client/Models/ChatCompletionRequest";
import ChatCompletionRequestMessageOneOf2 "mo:caffeineai-inference-client/Models/ChatCompletionRequestMessageOneOf2";
import Runtime "mo:core/Runtime";

module {
  public func runChat<system>(prompt : Text) : async* Text {
    let config = fromEnv<system>();
    let userMessage = ChatCompletionRequestMessageOneOf2.JSON.init({
      content = #string(prompt);
      role = #user;
    });
    let req = ChatCompletionRequest.JSON.init({
      messages = [#user(userMessage)];
      model = "router";
    });
    let resp = await* ChatApi.createChatCompletion(config, req);
    if (resp.choices.size() == 0) {
      Runtime.trap("Inference returned no choices");
    };
    resp.choices[0].message.content
      ?? Runtime.trap("Inference returned no text content");
  };
};
```

## 5. `model = "router"` — the platform picks the model

`"router"` is the only public model id, and it is a routing tier rather than a
model name. Caffeine Inference sizes each request to the complexity of the
query — a small fast model for simple prompts, a stronger one for hard
reasoning — and reports `"router"` back as the response `model`, so provider
names never reach the app.

- Always send `model = "router"`.
- Do not add a model dropdown, a "use GPT-4" toggle, or a `model` parameter on
  the backend endpoint. There is nothing for the user to choose.
- Steer quality with the prompt and with the declared sampling fields
  (`temperature`, `top_p`, `max_completion_tokens`), not with model selection.

## 6. Call shapes

- **Function form:** `ChatApi.createChatCompletion(config, req) : async*` — use `await*`.
- **Suite form:** `let api = ChatApi(config); api.createChatCompletion(req) : async`.

## 7. Available API surface — chat completions

`caffeineai-inference-client@0.4.1` is generated from
[`public-api-v0.1.0`](https://github.com/caffeinelabs/inference/releases/tag/public-api-v0.1.0):

| Module | Entry point | Route |
| --- | --- | --- |
| `ChatApi` | `createChatCompletion` | `POST /v1/chat/completions` |
| `ModelsApi` | `listModels` | `GET /v1/models` — catalog only; the model is always `"router"`, so an app never needs this |
| `Ephemeral` | `Broker.grant`, `mint` | `POST /v1/ephemeral-keys` — hand-written, not generated |

<!-- motoko-check:skip -->
```motoko
import ChatApi "mo:caffeineai-inference-client/Apis/ChatApi";
import { fromEnv } "mo:caffeineai-inference-client/Config";
```

Chat completions are the whole product surface. **Not available** on this host
(404, and not in the package): embeddings, images, audio, moderations, files,
legacy completions, Assistants, Responses, and raw `ic.http_request`. If the
spec genuinely needs an OpenAI-only API with a pasted `sk-...`, switch to
[`extension-openai`](../extension-openai/SKILL.md).

## 8. Cycles

Leave `cycles` unset (`null`): each call attaches the fee the IC charges for
that request, which is zero on subnets where outcalls are free. `?n` attaches exactly `n` cycles: the IC rejects the call when `n` is below its fee, and the call traps on a subnet where the canister holds fewer than `n`.

Streaming (`stream = ?true`) is unsupported in the canister — management-canister
HTTP returns the full body. Leave `stream = null`. The browser can stream; see
the frontend-direct path.

## 9. Things that will bite you

- Call `fromEnv<system>()` inside the `shared` method (or a `<system>` helper). A module-level `let config = fromEnv` will not compile.
- Surface failures. No credential pre-checks, no guard around `fromEnv`, and no empty result in place of an error. See §2.
- `model = "router"` — not `"gpt-4o-mini"`. See §5.
- User turns are `#user(ChatCompletionRequestMessageOneOf2.JSON.init({ content = #string(prompt); role = #user }))`.
- `JSON.init` for required fields; layer optionals with record update. Do not hand-list every `null`.
- `resp.choices[0].message.content` is `?Text`. Check `choices.size()` first.
- One chat call is one HTTP outcall inside an update call: budget seconds, not milliseconds. When a user waits on it, use the frontend-direct path.
- `Ephemeral.Broker` reuses a caller's key for 15 minutes and allows 30 mints per caller per hour. Pass your own `Limits` to change that.

# Frontend

The app is ready to chat on first load — there is nothing to configure.

1. **No API-key UI.** No settings page, no password input, no "configured?"
   indicator, no localStorage. If a spec or mock shows an "AI settings"
   screen, drop it.
2. **No model picker.** See §5.
3. **Backend path:** call the backend chat method (`chat(prompt)`), show a
   pending state while it runs (seconds), and offer a retry on trap.
4. **Frontend-direct path:** use the following client. It keeps the key in
   memory only, gets a new one when the gateway answers `401` (the key
   expired, or a deploy revoked it), and streams the reply.

```ts filepath=src/frontend/src/lib/inference.ts
export type InferenceCredentials = { baseUrl: string; apiKey: string; expiresAt: string };
export type ChatMessage = { role: "system" | "user" | "assistant"; content: string };

export function createInferenceChat(getCredentials: () => Promise<InferenceCredentials>) {
  let current: Promise<InferenceCredentials> | null = null;
  const credentials = (renew: boolean) => {
    if (renew || !current) {
      current = getCredentials();
      current.catch(() => { current = null; });
    }
    return current;
  };

  return async function chat(messages: ChatMessage[], onDelta?: (text: string) => void): Promise<string> {
    for (let attempt = 0; ; attempt++) {
      const { baseUrl, apiKey } = await credentials(attempt > 0);
      const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/v1/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ model: "router", messages, stream: true }),
      });
      if (response.status === 401 && attempt === 0) continue;
      if (!response.ok || !response.body) {
        const body = await response.json().catch(() => null);
        throw new Error(body?.error?.message ?? `Inference failed: HTTP ${response.status}`);
      }
      let text = "";
      let buffer = "";
      const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += value;
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          const data = line.startsWith("data:") ? line.slice(5).trim() : "";
          if (!data || data === "[DONE]") continue;
          const delta = JSON.parse(data).choices?.[0]?.delta?.content;
          if (delta) {
            text += delta;
            onDelta?.(delta);
          }
        }
      }
      if (!text) throw new Error("Inference returned no text");
      return text;
    }
  };
}
```

Create one client per signed-in session, for example
`const chat = createInferenceChat(() => actor.getInferenceCredentials());`.

- **Show first, save after.** Render the reply as it streams. Then save what
  the app keeps (a chat exchange, a translation) with an update call that does
  not block the UI and retries on failure. Say in the UI copy or docs that the
  last exchange can be lost if the tab closes before the save lands.
- **Ask for JSON in the prompt** when the feature needs fields (a translation
  with an article and a base form), and parse the final text, not the deltas.
- **Never** put the key in localStorage, sessionStorage, cookies, URLs, or
  logs.
