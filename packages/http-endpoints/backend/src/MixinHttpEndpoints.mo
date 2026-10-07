import Http "./Http";

mixin (
  onQuery : Http.Request -> Http.Response,
  onUpdate : Http.Request -> async Http.Response,
) {
  public query func http_request(req : Http.Request) : async Http.Response {
    onQuery(req);
  };

  public func http_request_update(req : Http.Request) : async Http.Response {
    await onUpdate(req);
  };
};
