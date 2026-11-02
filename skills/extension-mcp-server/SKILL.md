---
name: extension-mcp-server
description: >-
  Let users connect the app to Claude (or any MCP client such as Claude Code
  or Cursor) as a custom connector, so an AI assistant can read and change
  their data through tools the backend defines. Serves an MCP server from the
  backend canister; users sign in with Internet Identity on the app's own
  site and approve the client (OAuth 2.1 with PKCE). Load whenever the user
  or spec mentions MCP, a Claude connector, "connect to Claude/ChatGPT",
  or letting an AI agent use the app. NOT for calling an LLM from the app
  (use `extension-inference`); NOT for webhooks (use `extension-http-endpoints`).
version: 0.1.0
compatibility:
  mops:
    caffeineai-mcp-server: "~0.1.0"
    caffeineai-http-endpoints: "~0.1.0"
    caffeineai-authorization: "~1.0.1"
  npm:
    "@caffeineai/mcp-server": "~0.1.0"
caffeineai-subscription: [none]
---

# MCP server (Claude connector)

MCP server extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## How it works

1. The user copies the connector URL `https://<backend-canister-id>.icp0.io/mcp` from the app's settings and adds it in Claude under **Customize → Connectors → Add custom connector**.
2. Claude discovers the OAuth endpoints the backend serves, registers itself, and opens the app's `/mcp-authorize` page.
3. The user signs in with Internet Identity there, as anywhere else in the app, and clicks **Approve**. The backend issues tokens bound to that principal.
4. Every tool call runs as that user: `run` receives the same principal the user has in the app, so per-user data and role checks work unchanged.

The package handles the MCP protocol, the OAuth server, token storage (hashes only), refresh-token rotation, and revocation. The app writes the tools, the `/mcp-authorize` page, and a connector card in its settings.

# Backend

Use the prefabricated modules (do not modify them):

```mo:caffeineai-mcp-server/Mcp
module {
  public type State; // stable; create with Mcp.new() in the migration
  public type Server = {
    name : Text; // shown to the user in Claude
    version : Text;
    instructions : Text; // how the model should use the tools; "" for none
    tools : [Tool.Tool];
  };
  public func new() : State;
  public func handleQuery(req : Http.Request) : ?Http.Response; // null when the route is not MCP's
  public func handleUpdate(state : State, server : Server, req : Http.Request) : async* ?Http.Response;
};
```

```mo:caffeineai-mcp-server/Tool
module {
  public type Json = { #Null; #Bool : Bool; #Number : { #Int : Int; #Float : Float }; #String : Text; #Array : [Json]; #Object : [(Text, Json)] };
  public type Args = [(Text, Json)];
  public type Result = { #ok : Json; #err : Text }; // #err reaches the model as a readable tool error
  public type Tool = {
    name : Text; // snake_case
    description : Text; // what it does, when to use it, what it returns
    input : [(Text, Json)]; // argument name -> schema from the helpers below
    required : [Text];
    readOnly : Bool;
    run : (caller : Principal, args : Args) -> async* Result;
  };
  // Schemas
  public func string(description : Text) : Json;
  public func integer(description : Text) : Json;
  public func number(description : Text) : Json;
  public func boolean(description : Text) : Json;
  public func enumeration(values : [Text], description : Text) : Json;
  public func arrayOf(items : Json, description : Text) : Json;
  public func objectOf(properties : [(Text, Json)], required : [Text], description : Text) : Json;
  public func nullable(schema : Json) : Json; // also accepts JSON null
  // Argument readers: null when missing or of the wrong type
  public func text(args : Args, name : Text) : ?Text;
  public func nat(args : Args, name : Text) : ?Nat;
  public func int(args : Args, name : Text) : ?Int;
  public func float(args : Args, name : Text) : ?Float;
  public func bool(args : Args, name : Text) : ?Bool;
  public func isNull(args : Args, name : Text) : Bool; // sent as null, to clear a field
  public func field(args : Args, name : Text) : ?Json;
};
```

```mo:caffeineai-mcp-server/MixinMcpServer
mixin (mcpState : Mcp.State, accessControlState : AccessControl.AccessControlState) {
  // Candid methods for the frontend hooks; never call them from app code.
  public shared func _caffeineMcpSetSignInOrigin(origin : Text) : async (); // admin only
  public query func _caffeineMcpSignInOrigin() : async ?Text;
  public query func _caffeineMcpClient(clientId : Text) : async ?{ name : Text; redirectUris : [Text] };
  public shared func _caffeineMcpApprove(request : { clientId : Text; redirectUri : Text; codeChallenge : Text; codeChallengeMethod : Text }) : async { #ok : Text; #err : Text };
  public query func _caffeineMcpConnections() : async [{ id : Text; clientName : Text; createdAt : Int; expiresAt : Int }];
  public shared func _caffeineMcpRevoke(id : Text) : async ();
};
```

Add `mops add caffeineai-mcp-server caffeineai-http-endpoints`. Wire it into the **existing** actor in `main.mo`: keep `MixinAuthorization`, and chain MCP's handlers with `??` in front of any other HTTP routes (an actor declares `http_request` only once, through `MixinHttpEndpoints`).

```motoko filepath=src/backend/main.mo
import Array "mo:core/Array";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Http "mo:caffeineai-http-endpoints/Http";
import MixinHttpEndpoints "mo:caffeineai-http-endpoints/MixinHttpEndpoints";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import Mcp "mo:caffeineai-mcp-server/Mcp";
import MixinMcpServer "mo:caffeineai-mcp-server/MixinMcpServer";
import Tool "mo:caffeineai-mcp-server/Tool";

actor {
  let accessControlState : AccessControl.AccessControlState;
  let mcpState : Mcp.State;
  let notes : Map.Map<Principal, [Text]>;

  include MixinAuthorization(accessControlState, null);
  include MixinMcpServer(mcpState, accessControlState);

  func notesJson(list : [Text]) : Tool.Json {
    #Object([("notes", #Array(list.map<Text, Tool.Json>(func n = #String(n))))]);
  };

  transient let mcpServer : Mcp.Server = {
    name = "Notes";
    version = "1.0.0";
    instructions = "Reads and adds the signed-in user's notes.";
    tools = [
      {
        name = "list_notes";
        description = "Lists the user's notes, oldest first. Returns {notes: [string]}.";
        input = [];
        required = [];
        readOnly = true;
        run = func(caller : Principal, _args : Tool.Args) : async* Tool.Result {
          #ok(notesJson(notes.get(caller) ?? []));
        };
      },
      {
        name = "add_note";
        description = "Adds a note for the user. Returns all notes as {notes: [string]}.";
        input = [("text", Tool.string("The note, 1 to 500 characters."))];
        required = ["text"];
        readOnly = false;
        run = func(caller : Principal, args : Tool.Args) : async* Tool.Result {
          let ?text = Tool.text(args, "text") else return #err("text is required");
          if (text.size() == 0 or text.size() > 500) return #err("text must be 1 to 500 characters");
          let updated = (notes.get(caller) ?? []).concat([text]);
          notes.add(caller, updated);
          #ok(notesJson(updated));
        };
      },
    ];
  };

  func onHttpQuery(req : Http.Request) : Http.Response {
    Mcp.handleQuery(req) ?? Http.notFound();
  };

  func onHttpUpdate(req : Http.Request) : async Http.Response {
    (await* Mcp.handleUpdate(mcpState, mcpServer, req)) ?? Http.notFound();
  };

  include MixinHttpEndpoints(onHttpQuery, onHttpUpdate);
};
```

The migration chain head:

```motoko filepath=src/backend/migrations/00000000_000000.mo
import Map "mo:core/Map";
import AccessControl "mo:caffeineai-authorization/access-control";
import Mcp "mo:caffeineai-mcp-server/Mcp";

module {
  type NewActor = {
    accessControlState : AccessControl.AccessControlState;
    mcpState : Mcp.State;
    notes : Map.Map<Principal, [Text]>;
  };

  public func migration(_old : {}) : NewActor {
    {
      accessControlState = AccessControl.initState();
      mcpState = Mcp.new();
      notes = Map.empty();
    };
  };
};
```

In an existing app, add `mcpState = Mcp.new()` in a new migration instead.

## Writing tools

- **Declare the server `transient let`.** Tools are closures over actor state, which cannot be stable.
- **One tool per user intent**, named in `snake_case`. The description is the model's only manual: say what the tool does, when to use it, the argument formats (for example "dates are YYYY-MM-DD; convert 'tomorrow' yourself"), and the shape it returns.
- **Use `caller`, never an id from `args`, to decide whose data a tool touches.** Apply the same role checks as the Candid API, for example `AccessControl.hasPermission(accessControlState, caller, #user)`.
- **Return `#err` with a fix the model can act on** ("Session 12 not found. Use list_sessions to get valid ids"), not a trap. A trap fails the whole request.
- **Return objects.** An `#Object` result also reaches the client as `structuredContent`.
- **Set `readOnly = true`** for tools that change nothing; clients may skip confirmation for them.
- **Every MCP request is an update call**, so tools may `await` (HTTP outcalls, other canisters). State can change during an `await`: re-read what you checked before it.
- Mark optional arguments that can be cleared with `Tool.nullable(...)` and test them with `Tool.isNull(args, name)`.

# Frontend

```bash
pnpm add @caffeineai/mcp-server
```

```typescript
export declare function useMcpAuthorize(actor: McpAuthorizeActor | null | undefined): {
  // loading | ready | pending | redirecting | invalid | error
  status: McpAuthorizeStatus;
  clientName: string | null; // the name the client registered, for example "Claude"
  redirectHost: string | null; // where approval sends the user back
  error: string | null;
  approve: () => Promise<void>; // binds the client to the signed-in user, then redirects
  deny: () => void;
};

export declare function useMcpConnections(
  actor: McpConnectionsActor | null | undefined,
  options: { isAdmin: boolean },
): {
  url: string | null; // the connector URL to show and copy
  signInOrigin: string | null; // where MCP clients send users to sign in
  isSetUp: boolean; // false until an admin has opened the card on the live site
  connections: Array<{ id: string; clientName: string; createdAt: bigint; expiresAt: bigint }>;
  error: string | null;
  refresh: () => Promise<void>;
  revoke: (id: string) => Promise<void>;
  moveSignInHere: () => Promise<void>; // admin only: make this site's origin the sign-in origin
};
```

## `/mcp-authorize` page

Required: MCP clients send users to exactly `/mcp-authorize`.

- Register it with the app's TanStack Router as a child of the root route with `path: '/mcp-authorize'`, outside any layout that redirects signed-out users away (the query string must survive sign-in).
- Signed out: show a sign-in button (`login()` from `useInternetIdentity`). Signed in: call the hook with the authenticated actor.
- Show `clientName` and `redirectHost` with **Approve** and **Deny** buttons. Never approve on page load.

```typescript filepath=src/frontend/src/pages/McpAuthorizePage.tsx
import { useMcpAuthorize } from '@caffeineai/mcp-server';
import { useActor, useInternetIdentity } from '@caffeineai/core-infrastructure';
import { createActor } from '@/backend';

export function McpAuthorizePage() {
  const { isAuthenticated, login, isLoggingIn } = useInternetIdentity();
  const { actor } = useActor(createActor);
  const { status, clientName, redirectHost, error, approve, deny } = useMcpAuthorize(isAuthenticated ? actor : null);

  if (!isAuthenticated) {
    return (
      <button onClick={() => login()} disabled={isLoggingIn}>
        Sign in to connect
      </button>
    );
  }
  if (status === 'invalid') return <p>{error ?? 'This connection request is not valid. Start again from the client.'}</p>;
  if (status === 'error') return <p>Something went wrong: {error}</p>;
  if (status === 'redirecting') return <p>Returning to {clientName}…</p>;
  if (status === 'loading') return <p>Checking the request…</p>;

  return (
    <div>
      <p>
        <strong>{clientName}</strong> wants to use this app as you. It can do everything you can do here.
      </p>
      <p>You will return to {redirectHost}.</p>
      <button onClick={() => void approve()} disabled={status === 'pending'}>
        Approve
      </button>
      <button onClick={deny}>Deny</button>
    </div>
  );
}
```

## Connector card

Put it on a settings page for signed-in users. Pass `isAdmin` from `isCallerAdmin()`: the first time an admin opens the card on the live site, the hook stores the site's origin, which MCP clients need to find `/mcp-authorize`. While `isSetUp` is false, tell other users to ask an admin to open this page once. When an admin views the card on a different origin than `signInOrigin` (for example after adding a custom domain), offer a **Use this domain for sign-in** button calling `moveSignInHere()`.

The card shows:

- the `url` with a copy button,
- the steps: in Claude, open **Customize → Connectors → Add custom connector**, paste the URL, then sign in and approve when asked,
- `connections` (client name, connected date from `createdAt`, nanoseconds) with a **Disconnect** button calling `revoke(id)`.

## Rules of thumb

- **The connector URL is the backend canister**, `https://<backend-canister-id>.icp0.io/mcp`, never the app's domain. The hook builds it.
- **Drafts get their own canister**, so connections made against a draft stop working on the live app. Connect from the live site.
- **Tokens last one hour and refresh for 30 days of inactivity.** Clients refresh on their own; a user reconnects only after a month unused or after **Disconnect**.
- **No secret links.** Never hand out a token in a URL or build a second auth path; the OAuth flow is the only way in.

## Related

- [`extension-http-endpoints`](../extension-http-endpoints/SKILL.md) — the inbound HTTP mixin this builds on
- [`extension-authorization`](../extension-authorization/SKILL.md) — roles for `caller` checks in tools
