import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Json "mo:jayson/Json";
import Http "mo:caffeineai-http-endpoints/Http";
import Encoding "Encoding";
import Reply "Reply";

// OAuth 2.1 authorization server for MCP clients. The authorization page is
// the app's own frontend, where the user signs in with Internet Identity and
// approves the client; the canister issues opaque tokens bound to that
// principal and stores only their SHA-256 hashes.
module {
  public type Client = {
    name : Text;
    redirectUris : [Text];
    createdAt : Int;
  };

  public type Code = {
    clientId : Text;
    redirectUri : Text;
    codeChallenge : Text;
    user : Principal;
    expiresAt : Int;
  };

  public type Grant = {
    clientId : Text;
    user : Principal;
    createdAt : Int;
    var accessHash : Text;
    var accessExpiresAt : Int;
    var refreshHash : Text;
    var retiredRefreshHash : ?Text;
    var supersededRefreshHashes : [Text];
    var retried : Bool;
    var rotatedAt : Int;
    var refreshExpiresAt : Int;
  };

  // Codes are keyed by hash; `tokens` maps the hash of every live access,
  // refresh, and just-rotated refresh token to its grant id.
  public type State = {
    var signInOrigin : ?Text;
    clients : Map.Map<Text, Client>;
    codes : Map.Map<Text, Code>;
    grants : Map.Map<Text, Grant>;
    tokens : Map.Map<Text, Text>;
  };

  public type Approval = {
    clientId : Text;
    redirectUri : Text;
    codeChallenge : Text;
    codeChallengeMethod : Text;
  };

  public type Connection = {
    id : Text;
    clientName : Text;
    createdAt : Int;
    expiresAt : Int;
  };

  let second : Int = 1_000_000_000;
  let accessTtl : Int = 3_600_000_000_000;
  let refreshTtl : Int = 2_592_000_000_000_000;
  let codeTtl : Int = 300_000_000_000;
  let pendingClientTtl : Int = 86_400_000_000_000;
  let refreshRetryWindow : Int = 60_000_000_000;
  let maxPendingClients = 500;
  let maxRegistrationBytes = 8_192;
  let maxRedirectUriSize = 512;
  let maxCodesPerClient = 10;
  let maxGrantsPerUser = 20;
  let maxRetriesPerGrant = 5;

  public func new() : State {
    {
      var signInOrigin = null;
      clients = Map.empty<Text, Client>();
      codes = Map.empty<Text, Code>();
      grants = Map.empty<Text, Grant>();
      tokens = Map.empty<Text, Text>();
    };
  };

  func randomTokens(count : Nat) : async* [Text] {
    let ic = actor "aaaaa-aa" : actor { raw_rand : () -> async Blob };
    let seed = Encoding.hex(await ic.raw_rand());
    let out = List.empty<Text>();
    for (i in Nat.range(0, count)) out.add(Encoding.sha256Hex(seed # ":" # i.toText()));
    out.toArray();
  };

  let loopbackHosts = ["http://localhost", "http://127.0.0.1", "http://[::1]"];

  // What may follow a loopback host: an optional `:port`, then an optional
  // path. Anything else, such as `localhost.evil.com` or `localhost:@evil.com`,
  // names another host.
  func portThenPath(tail : Text, allowPath : Bool) : Bool {
    let ?afterColon = tail.stripStart(#char ':') else {
      return tail == "" or (allowPath and tail.startsWith(#char '/'));
    };
    let parts = afterColon.split(#char '/');
    let port = parts.next() ?? "";
    let hasPath = parts.next() != null;
    if (hasPath and not allowPath) return false;
    if (port == "" or port.size() > 5) return false;
    for (c in port.chars()) if (c < '0' or c > '9') return false;
    true;
  };

  // https; http on a loopback host (Claude Code); or a private-use scheme of
  // a native client (`cursor://`, `vscode://`, reverse-domain `com.example:`).
  public func validRedirectUri(uri : Text) : Bool {
    if (uri.size() > maxRedirectUriSize or uri.contains(#char '#')) return false;
    if (uri.startsWith(#text "https://")) return uri.size() > 8;
    for (prefix in loopbackHosts.values()) {
      switch (uri.stripStart(#text prefix)) {
        case (?tail) return portThenPath(tail, true);
        case null {};
      };
    };
    let parts = uri.split(#char ':');
    let ?scheme = parts.next() else return false;
    let rest = parts.join(":");
    if (scheme == "" or rest == "" or scheme == "http" or scheme == "javascript" or scheme == "data") return false;
    for (c in scheme.chars()) {
      if (not ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+')) return false;
    };
    scheme.contains(#char '.') or ["cursor", "vscode", "vscode-insiders"].contains(scheme);
  };

  public func validSignInOrigin(origin : Text) : Bool {
    switch (origin.stripStart(#text "https://")) {
      case (?host) return host != "" and not host.contains(#char '/') and not host.contains(#char '@');
      case null {};
    };
    for (prefix in loopbackHosts.values()) {
      switch (origin.stripStart(#text prefix)) {
        case (?tail) return portThenPath(tail, false);
        case null {};
      };
    };
    false;
  };

  func removeGrant(state : State, id : Text) {
    let ?grant = state.grants.get(id) else return;
    state.tokens.remove(grant.accessHash);
    state.tokens.remove(grant.refreshHash);
    switch (grant.retiredRefreshHash) {
      case (?hash) state.tokens.remove(hash);
      case null {};
    };
    for (hash in grant.supersededRefreshHashes.values()) state.tokens.remove(hash);
    state.grants.remove(id);
  };

  func clientsWithGrants(state : State) : Map.Map<Text, ()> {
    let live = Map.empty<Text, ()>();
    for (grant in state.grants.values()) live.add(grant.clientId, ());
    live;
  };

  // Clients without a connection are pending; they count against the
  // registration cap and expire a day after registering.
  func pendingClients(state : State) : Nat {
    let live = clientsWithGrants(state);
    var pending = 0;
    for (id in state.clients.keys()) if (not live.containsKey(id)) pending += 1;
    pending;
  };

  public func prune(state : State, now : Int) {
    let codes = List.empty<Text>();
    for ((hash, code) in state.codes.entries()) {
      if (code.expiresAt <= now) codes.add(hash);
    };
    for (hash in codes.values()) state.codes.remove(hash);

    let grants = List.empty<Text>();
    for ((id, grant) in state.grants.entries()) {
      if (grant.refreshExpiresAt <= now) grants.add(id);
    };
    for (id in grants.values()) removeGrant(state, id);

    let live = clientsWithGrants(state);
    let clients = List.empty<Text>();
    for ((id, client) in state.clients.entries()) {
      if (not live.containsKey(id) and now - client.createdAt > pendingClientTtl) clients.add(id);
    };
    for (id in clients.values()) state.clients.remove(id);
  };

  public func authenticate(state : State, token : Text, now : Int) : ?Principal {
    let hash = Encoding.sha256Hex(token);
    let ?id = state.tokens.get(hash) else return null;
    let ?grant = state.grants.get(id) else return null;
    if (grant.accessHash != hash or grant.accessExpiresAt <= now) return null;
    ?grant.user;
  };

  public func approve(state : State, caller : Principal, request : Approval, now : Int) : async* {
    #ok : Text;
    #err : Text;
  } {
    if (caller.isAnonymous()) return #err("Sign in before connecting a client");
    let ?client = state.clients.get(request.clientId) else return #err("Unknown client. Start the connection again from the client");
    if (not client.redirectUris.contains(request.redirectUri)) return #err("The redirect address is not registered for this client");
    if (request.codeChallengeMethod != "S256") return #err("The client must use PKCE with S256");
    if (request.codeChallenge.size() < 43 or request.codeChallenge.size() > 128) return #err("Invalid PKCE code challenge");
    prune(state, now);
    var outstanding = 0;
    for (c in state.codes.values()) if (c.clientId == request.clientId) outstanding += 1;
    if (outstanding >= maxCodesPerClient) return #err("Too many unfinished approvals for this client. Try again in a few minutes");
    let code = (await* randomTokens(1))[0];
    if (not state.clients.containsKey(request.clientId)) return #err("Unknown client. Start the connection again from the client");
    outstanding := 0;
    for (c in state.codes.values()) if (c.clientId == request.clientId) outstanding += 1;
    if (outstanding >= maxCodesPerClient) return #err("Too many unfinished approvals for this client. Try again in a few minutes");
    state.codes.add(
      Encoding.sha256Hex(code),
      {
        clientId = request.clientId;
        redirectUri = request.redirectUri;
        codeChallenge = request.codeChallenge;
        user = caller;
        expiresAt = now + codeTtl;
      },
    );
    #ok(code);
  };

  public func client(state : State, id : Text) : ?{ name : Text; redirectUris : [Text] } {
    let ?c = state.clients.get(id) else return null;
    ?{ name = c.name; redirectUris = c.redirectUris };
  };

  public func connections(state : State, user : Principal) : [Connection] {
    let out = List.empty<Connection>();
    for ((id, grant) in state.grants.entries()) {
      if (grant.user == user) {
        let clientName = switch (state.clients.get(grant.clientId)) {
          case (?c) c.name;
          case null "MCP client";
        };
        out.add({ id; clientName; createdAt = grant.createdAt; expiresAt = grant.refreshExpiresAt });
      };
    };
    out.toArray();
  };

  public func revoke(state : State, user : Principal, id : Text) {
    let ?grant = state.grants.get(id) else return;
    if (grant.user == user) removeGrant(state, id);
  };

  // ---- HTTP endpoints ----

  public func owns(path : Text) : Bool {
    path.startsWith(#text "/.well-known/oauth-") or path == "/register" or path == "/token";
  };

  public func handle(state : State, req : Http.Request, path : Text, now : Int) : async* ?Http.Response {
    if (not owns(path)) return null;
    let method = req.method.toUpper();
    if (method == "OPTIONS") return ?Reply.empty(204);
    if (path.startsWith(#text "/.well-known/oauth-protected-resource")) {
      if (method != "GET") return ?Reply.methodNotAllowed("GET, OPTIONS");
      return ?protectedResource(req);
    };
    if (path == "/.well-known/oauth-authorization-server") {
      if (method != "GET") return ?Reply.methodNotAllowed("GET, OPTIONS");
      return ?authorizationServer(state, req);
    };
    if (path == "/register") {
      if (method != "POST") return ?Reply.methodNotAllowed("POST, OPTIONS");
      return ?(await* register(state, req, now));
    };
    if (path == "/token") {
      if (method != "POST") return ?Reply.methodNotAllowed("POST, OPTIONS");
      return ?(await* token(state, req, now));
    };
    ?Reply.empty(404);
  };

  func strings(values : [Text]) : Json.Json {
    #Array(values.map<Text, Json.Json>(func v = #String(v)));
  };

  func protectedResource(req : Http.Request) : Http.Response {
    let base = Reply.baseUrl(req);
    Reply.json(
      200,
      #Object([
        ("resource", #String(base # "/mcp")),
        ("authorization_servers", strings([base])),
        ("bearer_methods_supported", strings(["header"])),
      ]),
    );
  };

  func authorizationServer(state : State, req : Http.Request) : Http.Response {
    let ?origin = state.signInOrigin else {
      return Reply.oauthError(503, "temporarily_unavailable", "The app's admin has not opened the connector settings yet");
    };
    let base = Reply.baseUrl(req);
    Reply.json(
      200,
      #Object([
        ("issuer", #String(base)),
        ("authorization_endpoint", #String(origin # "/mcp-authorize")),
        ("token_endpoint", #String(base # "/token")),
        ("registration_endpoint", #String(base # "/register")),
        ("response_types_supported", strings(["code"])),
        ("grant_types_supported", strings(["authorization_code", "refresh_token"])),
        ("code_challenge_methods_supported", strings(["S256"])),
        ("token_endpoint_auth_methods_supported", strings(["none"])),
      ]),
    );
  };

  func field(fields : [(Text, Json.Json)], name : Text) : ?Json.Json {
    for ((k, v) in fields.values()) {
      if (k == name) return ?v;
    };
    null;
  };

  func register(state : State, req : Http.Request, now : Int) : async* Http.Response {
    let invalid = func(description : Text) : Http.Response = Reply.oauthError(400, "invalid_client_metadata", description);
    if (req.body.size() > maxRegistrationBytes) return invalid("Registration metadata is too large");
    let ?body = Http.bodyText(req) else return invalid("Body must be UTF-8 JSON");
    let ?#Object(fields) = Json.parse(body) else return invalid("Body must be a JSON object");
    let ?#Array(rawUris) = field(fields, "redirect_uris") else return invalid("redirect_uris is required");
    let uris = List.empty<Text>();
    for (u in rawUris.values()) {
      let #String(uri) = u else return Reply.oauthError(400, "invalid_redirect_uri", "redirect_uris must be strings");
      if (not validRedirectUri(uri)) return Reply.oauthError(400, "invalid_redirect_uri", "Redirect URIs must use https, a loopback http address, or a native app scheme, in at most 512 characters");
      uris.add(uri);
    };
    if (uris.isEmpty() or uris.size() > 10) return invalid("Send between 1 and 10 redirect_uris");
    let name = switch (field(fields, "client_name")) {
      case (?#String(n)) if (n.size() > 100) Text.fromIter(n.chars().take(100)) else n;
      case _ "MCP client";
    };

    let full = func() : Http.Response = Reply.oauthError(503, "temporarily_unavailable", "Too many pending registrations. Try again later");
    prune(state, now);
    if (pendingClients(state) >= maxPendingClients) return full();
    let clientId = (await* randomTokens(1))[0];
    // Concurrent registrations all passed the check above before awaiting.
    if (pendingClients(state) >= maxPendingClients) return full();
    let redirectUris = uris.toArray();
    state.clients.add(clientId, { name; redirectUris; createdAt = now });
    Reply.json(
      201,
      #Object([
        ("client_id", #String(clientId)),
        ("client_id_issued_at", #Number(#Int(now / second))),
        ("client_name", #String(name)),
        ("redirect_uris", strings(redirectUris)),
        ("grant_types", strings(["authorization_code", "refresh_token"])),
        ("response_types", strings(["code"])),
        ("token_endpoint_auth_method", #String("none")),
      ]),
    );
  };

  func formField(form : [(Text, Text)], name : Text) : ?Text {
    for ((k, v) in form.values()) {
      if (k == name) return ?v;
    };
    null;
  };

  func token(state : State, req : Http.Request, now : Int) : async* Http.Response {
    let ?body = Http.bodyText(req) else return Reply.oauthError(400, "invalid_request", "Body must be form-encoded");
    prune(state, now);
    let form = Encoding.formDecode(body);
    let ?clientId = formField(form, "client_id") else return Reply.oauthError(401, "invalid_client", "client_id is required");
    switch (formField(form, "grant_type")) {
      case (?"authorization_code") await* exchangeCode(state, form, clientId, now);
      case (?"refresh_token") await* refresh(state, form, clientId, now);
      case _ Reply.oauthError(400, "unsupported_grant_type", "Use authorization_code or refresh_token");
    };
  };

  func exchangeCode(state : State, form : [(Text, Text)], clientId : Text, now : Int) : async* Http.Response {
    let invalid = func(description : Text) : Http.Response = Reply.oauthError(400, "invalid_grant", description);
    let ?code = formField(form, "code") else return Reply.oauthError(400, "invalid_request", "code is required");
    let ?verifier = formField(form, "code_verifier") else return Reply.oauthError(400, "invalid_request", "code_verifier is required");
    let ?redirectUri = formField(form, "redirect_uri") else return Reply.oauthError(400, "invalid_request", "redirect_uri is required");
    let hash = Encoding.sha256Hex(code);
    let ?stored = state.codes.get(hash) else return invalid("Unknown or used authorization code");
    state.codes.remove(hash);
    if (stored.expiresAt <= now) return invalid("The authorization code expired");
    if (stored.clientId != clientId or stored.redirectUri != redirectUri) return invalid("The code was issued to another client");
    if (Encoding.base64Url(Encoding.sha256(verifier.encodeUtf8())) != stored.codeChallenge) return invalid("PKCE verification failed");
    let fresh = await* randomTokens(3);
    let grant : Grant = {
      clientId;
      user = stored.user;
      createdAt = now;
      var accessHash = Encoding.sha256Hex(fresh[0]);
      var accessExpiresAt = now + accessTtl;
      var refreshHash = Encoding.sha256Hex(fresh[1]);
      var retiredRefreshHash = null;
      var supersededRefreshHashes = [];
      var retried = false;
      var rotatedAt = now;
      var refreshExpiresAt = now + refreshTtl;
    };
    let id = fresh[2];
    state.grants.add(id, grant);
    state.tokens.add(grant.accessHash, id);
    state.tokens.add(grant.refreshHash, id);
    dropOldestGrants(state, stored.user);
    tokenResponse(fresh[0], fresh[1]);
  };

  func dropOldestGrants(state : State, user : Principal) {
    label trim loop {
      var count = 0;
      var oldest : ?(Text, Int) = null;
      for ((id, grant) in state.grants.entries()) {
        if (grant.user == user) {
          count += 1;
          switch (oldest) {
            case (?(_, at)) if (grant.createdAt < at) oldest := ?(id, grant.createdAt);
            case null oldest := ?(id, grant.createdAt);
          };
        };
      };
      if (count <= maxGrantsPerUser) break trim;
      switch (oldest) {
        case (?(id, _)) removeGrant(state, id);
        case null break trim;
      };
    };
  };

  // Refresh tokens rotate on every use. The one just rotated out still works
  // once within a minute, for a client retrying after a lost response; that
  // retry supersedes the pair the lost response carried. Any other use of a
  // rotated-out token, or any use of a superseded one, means a token leaked
  // or was replayed, so the whole grant is revoked.
  func refresh(state : State, form : [(Text, Text)], clientId : Text, now : Int) : async* Http.Response {
    let invalid = func(description : Text) : Http.Response = Reply.oauthError(400, "invalid_grant", description);
    let ?presented = formField(form, "refresh_token") else return Reply.oauthError(400, "invalid_request", "refresh_token is required");
    let hash = Encoding.sha256Hex(presented);
    let ?id = state.tokens.get(hash) else return invalid("Unknown refresh token");
    let ?grant = state.grants.get(id) else return invalid("Unknown refresh token");
    let isRetry = grant.retiredRefreshHash == ?hash;
    let reused = grant.supersededRefreshHashes.contains(hash) or (isRetry and (grant.retried or now - grant.rotatedAt > refreshRetryWindow));
    if (reused) {
      removeGrant(state, id);
      return invalid("Refresh token reused; the connection was revoked");
    };
    if (not isRetry and grant.refreshHash != hash) return invalid("Unknown refresh token");
    if (grant.clientId != clientId) return invalid("The token was issued to another client");
    if (grant.refreshExpiresAt <= now) {
      removeGrant(state, id);
      return invalid("The connection expired; connect again");
    };
    let fresh = await* randomTokens(2);
    // The grant may have been revoked or rotated while waiting for randomness.
    if (not state.grants.containsKey(id)) return invalid("Unknown refresh token");
    if (not isRetry and grant.refreshHash == hash) {
      switch (grant.retiredRefreshHash) {
        case (?old) state.tokens.remove(old);
        case null {};
      };
      grant.retiredRefreshHash := ?hash;
      grant.retried := false;
      grant.rotatedAt := now;
    } else if (isRetry and grant.retiredRefreshHash == ?hash) {
      // A concurrent retry won the race, or retries keep happening.
      if (grant.retried or grant.supersededRefreshHashes.size() >= maxRetriesPerGrant) {
        removeGrant(state, id);
        return invalid("Refresh token reused; the connection was revoked");
      };
      grant.retried := true;
      grant.supersededRefreshHashes := grant.supersededRefreshHashes.concat([grant.refreshHash]);
    } else {
      return invalid("Unknown refresh token");
    };
    state.tokens.remove(grant.accessHash);
    grant.accessHash := Encoding.sha256Hex(fresh[0]);
    grant.accessExpiresAt := now + accessTtl;
    grant.refreshHash := Encoding.sha256Hex(fresh[1]);
    grant.refreshExpiresAt := now + refreshTtl;
    state.tokens.add(grant.accessHash, id);
    state.tokens.add(grant.refreshHash, id);
    tokenResponse(fresh[0], fresh[1]);
  };

  func tokenResponse(access : Text, refreshToken : Text) : Http.Response {
    Reply.json(
      200,
      #Object([
        ("access_token", #String(access)),
        ("token_type", #String("Bearer")),
        ("expires_in", #Number(#Int(accessTtl / second))),
        ("refresh_token", #String(refreshToken)),
      ]),
    );
  };
};
