import { test } "mo:test";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Tokens "../src/tokens";
import VerificationTokens "../src/verificationTokens";

let hour : Int = 3_600_000_000_000;
let seed : Blob = "\00\01\02\03\04\05\06\07\08\09\0a\0b\0c\0d\0e\0f\10\11\12\13\14\15\16\17\18\19\1a\1b\1c\1d\1e\1f";

test("a token is consumed once and yields the address it was sent to", func() {
  let state = VerificationTokens.new();
  VerificationTokens.add(state, "tok", "alice@example.com", 0);
  assert VerificationTokens.consume(state, "tok", hour) == ?"alice@example.com";
  assert VerificationTokens.consume(state, "tok", hour) == null;
  assert VerificationTokens.size(state) == 0;
});

test("an unknown token yields nothing and changes nothing", func() {
  let state = VerificationTokens.new();
  VerificationTokens.add(state, "tok", "alice@example.com", 0);
  assert VerificationTokens.consume(state, "other", hour) == null;
  assert VerificationTokens.size(state) == 1;
});

test("a token older than 24 hours yields nothing and is dropped", func() {
  let state = VerificationTokens.new();
  VerificationTokens.add(state, "tok", "alice@example.com", 0);
  assert VerificationTokens.consume(state, "tok", 24 * hour + 1) == null;
  assert VerificationTokens.size(state) == 0;
});

test("a token exactly 24 hours old is still valid", func() {
  let state = VerificationTokens.new();
  VerificationTokens.add(state, "tok", "alice@example.com", 0);
  assert VerificationTokens.consume(state, "tok", 24 * hour) == ?"alice@example.com";
});

test("prune drops the expired tokens and keeps the rest", func() {
  let state = VerificationTokens.new();
  VerificationTokens.add(state, "old", "alice@example.com", 0);
  VerificationTokens.add(state, "fresh", "bob@example.com", 20 * hour);
  VerificationTokens.prune(state, 30 * hour);
  assert VerificationTokens.size(state) == 1;
  assert VerificationTokens.consume(state, "fresh", 30 * hour) == ?"bob@example.com";
});

test("derive is deterministic, 64 hex digits, and distinct per counter and per part", func() {
  let a = Tokens.derive(seed, 0, ["alice@example.com"]);
  assert a == Tokens.derive(seed, 0, ["alice@example.com"]);
  assert a.size() == 64;
  assert Iter.all(Text.toIter(a), func(c : Char) : Bool { (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') });
  assert a != Tokens.derive(seed, 1, ["alice@example.com"]);
  assert a != Tokens.derive(seed, 0, ["bob@example.com"]);
  assert a != Tokens.derive(seed, 0, ["alice@example.com", "1"]);
});
