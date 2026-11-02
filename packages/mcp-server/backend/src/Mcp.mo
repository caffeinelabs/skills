import Array "mo:core/Array";
import List "mo:core/List";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Json "mo:jayson/Json";
import Http "mo:caffeineai-http-endpoints/Http";
import OAuth "OAuth";
import Reply "Reply";
import Tool "Tool";

// MCP server (Streamable HTTP, JSON responses only) at `/mcp` on the backend
// canister, with the OAuth endpoints MCP clients discover next to it.
module {
  public type State = OAuth.State;

  public type Server = {
    name : Text;
    version : Text;
    instructions : Text;
    tools : [Tool.Tool];
  };

  type Json = Json.Json;

  let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"];

  public func new() : State = OAuth.new();

  func isMcpPath(path : Text) : Bool = path == "/mcp" or path == "/mcp/";

  // Every route is answered from the update path: query responses are not
  // certified, and the default gateway rejects uncertified responses.
  public func handleQuery(req : Http.Request) : ?Http.Response {
    let path = Http.path(req.url);
    if (isMcpPath(path) or OAuth.owns(path)) ?Http.upgrade() else null;
  };

  public func handleUpdate(state : State, server : Server, req : Http.Request) : async* ?Http.Response {
    let path = Http.path(req.url);
    let now = Time.now();
    if (isMcpPath(path)) return ?(await* handleMcp(state, server, req, now));
    await* OAuth.handle(state, req, path, now);
  };

  func bearer(req : Http.Request) : ?Text {
    let ?value = Http.header(req, "authorization") else return null;
    let ?scheme = value.split(#char ' ').next() else return null;
    if (scheme.toLower() != "bearer") return null;
    let ?token = value.stripStart(#text(scheme # " ")) else return null;
    ?token.trim(#char ' ');
  };

  func handleMcp(state : State, server : Server, req : Http.Request, now : Int) : async* Http.Response {
    let method = req.method.toUpper();
    if (method == "OPTIONS") return Reply.empty(204);
    if (method != "POST") return Reply.methodNotAllowed("POST, OPTIONS");
    let caller = switch (bearer(req)) {
      case (?token) OAuth.authenticate(state, token, now);
      case null null;
    };
    let ?user = caller else {
      let metadata = Reply.baseUrl(req) # "/.well-known/oauth-protected-resource/mcp";
      return Reply.raw(
        401,
        [("www-authenticate", "Bearer resource_metadata=\"" # metadata # "\""), ("content-type", "application/json")],
        rpcError(#Null, -32001, "Sign in required").stringify(),
      );
    };
    let ?body = Http.bodyText(req) else return Reply.json(200, rpcError(#Null, -32700, "Parse error: body is not UTF-8"));
    let ?message = Json.parse(body) else return Reply.json(200, rpcError(#Null, -32700, "Parse error: body is not valid JSON"));
    switch (message) {
      case (#Array(items)) {
        if (items.size() == 0) return Reply.json(200, rpcError(#Null, -32600, "Invalid Request: empty batch"));
        let replies = List.empty<Json>();
        for (item in items.values()) {
          switch (await* handleMessage(server, user, item)) {
            case (?r) replies.add(r);
            case null {};
          };
        };
        if (replies.isEmpty()) Reply.empty(202) else Reply.json(200, #Array(replies.toArray()));
      };
      case _ {
        switch (await* handleMessage(server, user, message)) {
          case (?r) Reply.json(200, r);
          case null Reply.empty(202);
        };
      };
    };
  };

  func rpcError(id : Json, code : Int, message : Text) : Json {
    #Object([
      ("jsonrpc", #String("2.0")),
      ("id", id),
      ("error", #Object([("code", #Number(#Int(code))), ("message", #String(message))])),
    ]);
  };

  func rpcResult(id : Json, result : Json) : Json {
    #Object([("jsonrpc", #String("2.0")), ("id", id), ("result", result)]);
  };

  // Null for notifications and for responses the client sends back.
  func handleMessage(server : Server, user : Principal, message : Json) : async* ?Json {
    let #Object(fields) = message else return ?rpcError(#Null, -32600, "Invalid Request: expected a JSON-RPC object");
    let id = Tool.field(fields, "id");
    let ?#String(method) = Tool.field(fields, "method") else {
      if (id != null and Tool.field(fields, "result") == null and Tool.field(fields, "error") == null) {
        return ?rpcError(id ?? #Null, -32600, "Invalid Request: missing method");
      };
      return null;
    };
    let ?requestId = id else return null;
    let params : Tool.Args = switch (Tool.field(fields, "params")) {
      case (?#Object(p)) p;
      case (null or ?#Null) [];
      case _ return ?rpcError(requestId, -32602, "Invalid params: params must be an object");
    };
    let reply = switch (method) {
      case "initialize" rpcResult(requestId, initialize(server, params));
      case "ping" rpcResult(requestId, #Object([]));
      case "tools/list" rpcResult(requestId, #Object([("tools", #Array(server.tools.map<Tool.Tool, Json>(describe)))]));
      case "tools/call" await* callTool(server, user, requestId, params);
      case _ rpcError(requestId, -32601, "Method not found: " # method);
    };
    ?reply;
  };

  func initialize(server : Server, params : Tool.Args) : Json {
    let requested = Tool.text(params, "protocolVersion") ?? "";
    let version = if (protocolVersions.contains(requested)) requested else protocolVersions[0];
    let fields = List.fromArray<(Text, Json)>([
      ("protocolVersion", #String(version)),
      ("capabilities", #Object([("tools", #Object([]))])),
      ("serverInfo", #Object([("name", #String(server.name)), ("version", #String(server.version))])),
    ]);
    if (server.instructions != "") fields.add(("instructions", #String(server.instructions)));
    #Object(fields.toArray());
  };

  func describe(tool : Tool.Tool) : Json {
    #Object([
      ("name", #String(tool.name)),
      ("description", #String(tool.description)),
      (
        "inputSchema",
        #Object([
          ("type", #String("object")),
          ("properties", #Object(tool.input)),
          ("required", #Array(tool.required.map<Text, Json>(func r = #String(r)))),
        ]),
      ),
      ("annotations", #Object([("readOnlyHint", #Bool(tool.readOnly))])),
    ]);
  };

  func callTool(server : Server, user : Principal, id : Json, params : Tool.Args) : async* Json {
    let ?name = Tool.text(params, "name") else return rpcError(id, -32602, "Invalid params: tool name is required");
    let args : Tool.Args = switch (Tool.field(params, "arguments")) {
      case (?#Object(a)) a;
      case (null or ?#Null) [];
      case _ return rpcError(id, -32602, "Invalid params: arguments must be an object");
    };
    let ?tool = server.tools.find(func(t : Tool.Tool) : Bool = t.name == name) else {
      return rpcError(id, -32602, "Unknown tool: " # name);
    };
    let result = switch (await* tool.run(user, args)) {
      case (#ok(value)) {
        let content = #Array([#Object([("type", #String("text")), ("text", #String(value.stringify()))])]);
        switch (value) {
          case (#Object(_)) #Object([("content", content), ("structuredContent", value), ("isError", #Bool(false))]);
          case _ #Object([("content", content), ("isError", #Bool(false))]);
        };
      };
      case (#err(message)) {
        #Object([
          ("content", #Array([#Object([("type", #String("text")), ("text", #String(message))])])),
          ("isError", #Bool(true)),
        ]);
      };
    };
    rpcResult(id, result);
  };
};
