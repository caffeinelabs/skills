/// Unit tests for pure Http helpers. No replica needed.

import { test } "mo:test";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Http "../src/Http";

func req(method : Text, url : Text, headers : [Http.HeaderField], body : Blob) : Http.Request {
  { method; url; headers; body; certificate_version = null };
};

test("path strips query string", func() {
  assert Http.path("/webhook?sig=abc") == "/webhook";
});

test("path without query is unchanged", func() {
  assert Http.path("/health") == "/health";
});

test("header is case-insensitive", func() {
  let r = req("POST", "/webhook", [("Stripe-Signature", "v1=abc")], "".encodeUtf8());
  assert Http.header(r, "stripe-signature") == ?"v1=abc";
});

test("header returns null when absent", func() {
  let r = req("POST", "/webhook", [("content-type", "text/plain")], "".encodeUtf8());
  assert Http.header(r, "stripe-signature") == null;
});

test("bodyText decodes UTF-8", func() {
  let r = req("POST", "/webhook", [], "payload".encodeUtf8());
  assert Http.bodyText(r) == ?"payload";
});

test("bodyText is null for invalid UTF-8", func() {
  let r = req("POST", "/webhook", [], Blob.fromArray([255, 254]));
  assert Http.bodyText(r) == null;
});

test("upgrade asks the gateway to re-issue as update", func() {
  let res = Http.upgrade();
  assert res.status_code == 200;
  assert res.upgrade == ?true;
});

test("notFound is 404", func() {
  assert Http.notFound().status_code == 404;
});
