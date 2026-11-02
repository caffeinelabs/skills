/// Unit tests for the security-critical pure logic. No replica needed.

import { test } "mo:test";
import Array "mo:core/Array";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import Http "mo:caffeineai-http-endpoints/Http";
import Encoding "../src/Encoding";
import Mcp "../src/Mcp";
import OAuth "../src/OAuth";
import Tool "../src/Tool";

test(
  "PKCE S256 matches the RFC 7636 example",
  func() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    assert Encoding.base64Url(Encoding.sha256(verifier.encodeUtf8())) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";
  },
);

test(
  "base64Url leaves out padding",
  func() {
    assert Encoding.base64Url("f".encodeUtf8()) == "Zg";
    assert Encoding.base64Url("fo".encodeUtf8()) == "Zm8";
    assert Encoding.base64Url("foo".encodeUtf8()) == "Zm9v";
    assert Encoding.base64Url("foob".encodeUtf8()) == "Zm9vYg";
  },
);

test(
  "sha256Hex hashes UTF-8 text",
  func() {
    assert Encoding.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  },
);

test(
  "formDecode handles +, percent escapes, UTF-8, and = in values",
  func() {
    let form = Encoding.formDecode("grant_type=authorization_code&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb%3Fa%3Db&name=caf%C3%A9+bar&x=a=b");
    assert form == [
      ("grant_type", "authorization_code"),
      ("redirect_uri", "https://claude.ai/cb?a=b"),
      ("name", "café bar"),
      ("x", "a=b"),
    ];
  },
);

test(
  "formDecode drops pairs with broken escapes",
  func() {
    assert Encoding.formDecode("a=%ZZ&b=1&c=%4") == [("b", "1")];
  },
);

test(
  "sign-in origin must be an https origin without a path",
  func() {
    assert OAuth.validSignInOrigin("https://myapp.caffeine.xyz");
    assert OAuth.validSignInOrigin("http://localhost:5173");
    assert not OAuth.validSignInOrigin("https://myapp.caffeine.xyz/");
    assert not OAuth.validSignInOrigin("https://myapp.caffeine.xyz/evil");
    assert not OAuth.validSignInOrigin("http://myapp.caffeine.xyz");
    assert not OAuth.validSignInOrigin("https://");
    assert not OAuth.validSignInOrigin("http://localhost.evil.com");
    assert not OAuth.validSignInOrigin("http://localhost:5173/path");
  },
);

func grantState(now : Int) : OAuth.State {
  let state = OAuth.new();
  let user = Principal.fromText("2vxsx-fae");
  state.grants.add(
    "g1",
    {
      clientId = "c1";
      user;
      createdAt = now;
      var accessHash = Encoding.sha256Hex("access-1");
      var accessExpiresAt = now + 100;
      var refreshHash = Encoding.sha256Hex("refresh-1");
      var retiredRefreshHash = null : ?Text;
      var supersededRefreshHashes = [] : [Text];
      var retried = false;
      var rotatedAt = now;
      var refreshExpiresAt = now + 1_000;
    },
  );
  state.tokens.add(Encoding.sha256Hex("access-1"), "g1");
  state.tokens.add(Encoding.sha256Hex("refresh-1"), "g1");
  state;
};

test(
  "authenticate accepts a live access token only",
  func() {
    let state = grantState(0);
    assert OAuth.authenticate(state, "access-1", 50) == ?Principal.fromText("2vxsx-fae");
    assert OAuth.authenticate(state, "access-1", 100) == null;
    assert OAuth.authenticate(state, "refresh-1", 50) == null;
    assert OAuth.authenticate(state, "unknown", 50) == null;
  },
);

test(
  "revoke removes the grant and its tokens",
  func() {
    let state = grantState(0);
    OAuth.revoke(state, Principal.fromText("2vxsx-fae"), "g1");
    assert OAuth.authenticate(state, "access-1", 50) == null;
    assert state.tokens.size() == 0;
  },
);

test(
  "prune drops expired grants",
  func() {
    let state = grantState(0);
    OAuth.prune(state, 1_000);
    assert state.grants.size() == 0;
    assert state.tokens.size() == 0;
  },
);

func request(method : Text, url : Text) : Http.Request {
  { method; url; headers = []; body = "".encodeUtf8(); certificate_version = null };
};

test(
  "handleQuery upgrades MCP and OAuth routes and ignores the rest",
  func() {
    for (url in ["/mcp", "/mcp/", "/token", "/register", "/.well-known/oauth-authorization-server", "/.well-known/oauth-protected-resource/mcp"].values()) {
      switch (Mcp.handleQuery(request("POST", url))) {
        case (?res) assert res.upgrade == ?true;
        case null assert false;
      };
    };
    assert Mcp.handleQuery(request("GET", "/health")) == null;
  },
);

test(
  "argument readers tell missing, null, and wrong types apart",
  func() {
    let args : Tool.Args = [("n", #Number(#Float(3.0))), ("neg", #Number(#Int(-1))), ("s", #String("x")), ("z", #Null)];
    assert Tool.nat(args, "n") == ?3;
    assert Tool.nat(args, "neg") == null;
    assert Tool.int(args, "neg") == ?(-1);
    assert Tool.text(args, "s") == ?"x";
    assert Tool.text(args, "n") == null;
    assert Tool.isNull(args, "z");
    assert not Tool.isNull(args, "missing");
  },
);

test(
  "redirect URIs: https, loopback http, and native app schemes only",
  func() {
    assert OAuth.validRedirectUri("https://claude.ai/api/mcp/auth_callback");
    assert OAuth.validRedirectUri("http://localhost:33418/callback");
    assert OAuth.validRedirectUri("http://127.0.0.1/cb");
    assert OAuth.validRedirectUri("cursor://anysphere.cursor-mcp/oauth/callback");
    assert OAuth.validRedirectUri("com.example.app:/oauth");
    assert not OAuth.validRedirectUri("http://evil.example/cb");
    assert not OAuth.validRedirectUri("http://localhost.evil.example/cb");
    assert not OAuth.validRedirectUri("http://localhost:@evil.com/cb");
    assert not OAuth.validRedirectUri("http://127.0.0.1:80@evil.com/");
    assert not OAuth.validRedirectUri("javascript:alert(1)");
    assert not OAuth.validRedirectUri("myapp://cb");
    assert not OAuth.validRedirectUri("https://claude.ai/cb#frag");
    assert not OAuth.validRedirectUri("https://claude.ai/" # Text.join(Array.repeat("a", 600).values(), ""));
  },
);

test(
  "prune keeps clients with a connection and expires the rest after a day",
  func() {
    let day = 86_400_000_000_000;
    let state = grantState(day);
    state.clients.add("c1", { name = "Claude"; redirectUris = []; createdAt = 0 });
    state.clients.add("c2", { name = "Spam"; redirectUris = []; createdAt = 0 });
    OAuth.prune(state, day + 1);
    assert state.clients.containsKey("c1");
    assert not state.clients.containsKey("c2");
  },
);
