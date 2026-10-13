import { test } "mo:test";
import UnsubscribeTokens "../src/unsubscribeTokens";

test("a subscription has no token until one is put", func() {
  let state = UnsubscribeTokens.new();
  assert UnsubscribeTokens.get(state, "alice@example.com", 1) == null;
  assert UnsubscribeTokens.lookup(state, "tok") == null;
  assert UnsubscribeTokens.size(state) == 0;
});

test("a put token is found by subscription and by token", func() {
  let state = UnsubscribeTokens.new();
  UnsubscribeTokens.put(state, "tok", "alice@example.com", 1);
  assert UnsubscribeTokens.get(state, "alice@example.com", 1) == ?"tok";
  assert UnsubscribeTokens.lookup(state, "tok") == ?{ email = "alice@example.com"; topicId = 1 };
  assert UnsubscribeTokens.size(state) == 1;
});

test("tokens are per topic and per subscriber", func() {
  let state = UnsubscribeTokens.new();
  UnsubscribeTokens.put(state, "tok-1", "alice@example.com", 1);
  UnsubscribeTokens.put(state, "tok-2", "alice@example.com", 2);
  UnsubscribeTokens.put(state, "tok-3", "bob@example.com", 1);
  assert UnsubscribeTokens.get(state, "alice@example.com", 2) == ?"tok-2";
  assert UnsubscribeTokens.get(state, "bob@example.com", 1) == ?"tok-3";
  assert UnsubscribeTokens.get(state, "bob@example.com", 2) == null;
  assert UnsubscribeTokens.size(state) == 3;
});

test("remove drops both directions and leaves other subscriptions alone", func() {
  let state = UnsubscribeTokens.new();
  UnsubscribeTokens.put(state, "tok-1", "alice@example.com", 1);
  UnsubscribeTokens.put(state, "tok-2", "alice@example.com", 2);
  UnsubscribeTokens.remove(state, "alice@example.com", 1);
  assert UnsubscribeTokens.get(state, "alice@example.com", 1) == null;
  assert UnsubscribeTokens.lookup(state, "tok-1") == null;
  assert UnsubscribeTokens.get(state, "alice@example.com", 2) == ?"tok-2";
  assert UnsubscribeTokens.size(state) == 1;
});

test("removing a subscription without a token is a no-op", func() {
  let state = UnsubscribeTokens.new();
  UnsubscribeTokens.put(state, "tok-1", "alice@example.com", 1);
  UnsubscribeTokens.remove(state, "bob@example.com", 1);
  assert UnsubscribeTokens.size(state) == 1;
});
