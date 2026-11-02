import Array "mo:core/Array";
import Text "mo:core/Text";
import Json "mo:jayson/Json";
import Http "mo:caffeineai-http-endpoints/Http";

module {
  let cors : [Http.HeaderField] = [
    ("access-control-allow-origin", "*"),
    ("access-control-allow-methods", "GET, POST, OPTIONS"),
    ("access-control-allow-headers", "authorization, content-type, accept, mcp-protocol-version, mcp-session-id"),
    ("access-control-expose-headers", "www-authenticate, mcp-session-id"),
  ];

  public func raw(status : Nat16, headers : [Http.HeaderField], body : Text) : Http.Response {
    {
      status_code = status;
      headers = cors.concat(headers);
      body = body.encodeUtf8();
      streaming_strategy = null;
      upgrade = null;
    };
  };

  public func json(status : Nat16, value : Json.Json) : Http.Response {
    raw(status, [("content-type", "application/json"), ("cache-control", "no-store")], value.stringify());
  };

  public func empty(status : Nat16) : Http.Response {
    raw(status, [], "");
  };

  public func oauthError(status : Nat16, code : Text, description : Text) : Http.Response {
    json(status, #Object([("error", #String(code)), ("error_description", #String(description))]));
  };

  public func methodNotAllowed(allow : Text) : Http.Response {
    raw(405, [("allow", allow)], "");
  };

  public func baseUrl(req : Http.Request) : Text {
    "https://" # (Http.header(req, "host") ?? "");
  };
};
