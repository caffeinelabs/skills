/// Unit tests for `Predicate.eval` and `Predicate.compare`. Pure module,
/// no actor needed — runs in the `mops test` interpreter.

import {test} "mo:test";
import Map    "mo:core/Map";
import Predicate "../src/Predicate";
import Types     "../src/Types";

type Value = Types.Value;

/// Tiny row builder: turn `[(name, value)]` into a `Predicate.Row`.
/// Resolves exactly one segment, matching `Entity.makeRow` — multi-segment
/// paths are edge traversals, which live above the predicate layer.
func row(cells : [(Text, Value)]) : Predicate.Row {
  let m = Map.empty<Text, Value>();
  for ((k, v) in cells.values()) { m.add(k, v) };
  {
    get = func (path : Types.Path) : ?Value {
      if (path.size() != 1) null else m.get(path[0])
    };
  };
};

test("eq matches the same scalar", func () {
  let r = row([("name", #text("alice"))]);
  assert Predicate.eval(#eq(["name"], #text("alice")), r);
  assert not Predicate.eval(#eq(["name"], #text("bob")), r);
});

test("ne is the negation of eq", func () {
  let r = row([("country", #text("DE"))]);
  assert Predicate.eval(#ne(["country"], #text("UK")), r);
  assert not Predicate.eval(#ne(["country"], #text("DE")), r);
});

test("lt / le / gt / ge cover ordering on Nat", func () {
  let r = row([("amount", #nat(42))]);
  assert     Predicate.eval(#lt(["amount"], #nat(100)), r);
  assert not Predicate.eval(#lt(["amount"], #nat(42)),  r);
  assert     Predicate.eval(#le(["amount"], #nat(42)),  r);
  assert     Predicate.eval(#le(["amount"], #nat(43)),  r);
  assert     Predicate.eval(#gt(["amount"], #nat(0)),   r);
  assert not Predicate.eval(#gt(["amount"], #nat(42)),  r);
  assert     Predicate.eval(#ge(["amount"], #nat(42)),  r);
  assert not Predicate.eval(#ge(["amount"], #nat(43)),  r);
});

test("missing field never satisfies any relation (strict null)", func () {
  let r = row([("amount", #nat(10))]);
  assert not Predicate.eval(#eq (["missing"], #nat(10)), r);
  assert not Predicate.eval(#lt (["missing"], #nat(99)), r);
  assert not Predicate.eval(#ge (["missing"], #nat(0)),  r);
  // `ne` of a missing field is still false because `matches(null, _, _)`
  // is false — and `#ne` is its negation: not false = true. Document the
  // resulting behavior explicitly so callers don't trip on it.
  assert Predicate.eval(#ne(["missing"], #nat(10)), r);
});

test("and_ short-circuits to all-true semantics", func () {
  let r = row([("age", #nat(30)), ("country", #text("DE"))]);
  assert     Predicate.eval(#and_([
    #ge(["age"], #nat(18)),
    #eq(["country"], #text("DE")),
  ]), r);
  assert not Predicate.eval(#and_([
    #ge(["age"], #nat(18)),
    #eq(["country"], #text("UK")),
  ]), r);
  // empty and_ is vacuously true
  assert Predicate.eval(#and_([]), r);
});

test("or_ matches at least one branch", func () {
  let r = row([("country", #text("DE"))]);
  assert     Predicate.eval(#or_([
    #eq(["country"], #text("UK")),
    #eq(["country"], #text("DE")),
  ]), r);
  assert not Predicate.eval(#or_([
    #eq(["country"], #text("UK")),
    #eq(["country"], #text("FR")),
  ]), r);
  // empty or_ is vacuously false
  assert not Predicate.eval(#or_([]), r);
});

test("in_ matches when value is among the candidates", func () {
  let r = row([("authorId", #nat(2)), ("country", #text("DE"))]);
  assert     Predicate.eval(#in_(["authorId"], [#nat(1), #nat(2), #nat(3)]), r);
  assert not Predicate.eval(#in_(["authorId"], [#nat(1), #nat(3)]), r);
  // empty candidate list matches nothing
  assert not Predicate.eval(#in_(["authorId"], []), r);
  // bridges across nat/int (compare unifies them)
  assert Predicate.eval(#in_(["authorId"], [#int(2)]), r);
  // works on text + null + missing field
  assert     Predicate.eval(#in_(["country"], [#text("FR"), #text("DE")]), r);
  assert not Predicate.eval(#in_(["country"], [#text("FR"), #text("UK")]), r);
  assert not Predicate.eval(#in_(["missing"],  [#text("DE")]), r);
});

test("contains / startsWith / endsWith are case-sensitive substring relations", func () {
  let r = row([("subject", #text("Refund request for order 42"))]);
  assert     Predicate.eval(#contains(["subject"], #text("Refund")), r);
  assert     Predicate.eval(#contains(["subject"], #text("order 42")), r);
  assert not Predicate.eval(#contains(["subject"], #text("refund")), r);   // case matters
  assert not Predicate.eval(#contains(["subject"], #text("cancel")), r);
  assert     Predicate.eval(#startsWith(["subject"], #text("Refund")), r);
  assert not Predicate.eval(#startsWith(["subject"], #text("refund")), r);
  assert not Predicate.eval(#startsWith(["subject"], #text("order")), r);
  assert     Predicate.eval(#endsWith(["subject"], #text("42")), r);
  assert not Predicate.eval(#endsWith(["subject"], #text("Refund")), r);
  // empty needle matches everywhere
  assert Predicate.eval(#contains(["subject"], #text("")), r);
});

test("icontains folds case on both sides", func () {
  let r = row([("subject", #text("ReFuND Request"))]);
  assert     Predicate.eval(#icontains(["subject"], #text("refund")), r);
  assert     Predicate.eval(#icontains(["subject"], #text("REFUND")), r);
  assert     Predicate.eval(#icontains(["subject"], #text("und req")), r);
  assert not Predicate.eval(#icontains(["subject"], #text("cancel")), r);
  // Non-ASCII folding works in compiled canisters (Rust RTS lowercasing),
  // but the mops-test interpreter's `textLowercase` is ASCII-only, so we
  // only assert ASCII behavior here.
  let u = row([("name", #text("ÜBER Straße"))]);
  assert Predicate.eval(#icontains(["name"], #text("straße")), u);
});

test("text ops are false on non-text or missing fields", func () {
  let r = row([("amount", #nat(42)), ("note", #null_)]);
  assert not Predicate.eval(#contains  (["amount"],  #text("4")), r);
  assert not Predicate.eval(#icontains (["note"],    #text("x")), r);
  assert not Predicate.eval(#startsWith(["missing"], #text("a")), r);
  assert not Predicate.eval(#endsWith  (["missing"], #text("a")), r);
  // non-text needle never matches either
  assert not Predicate.eval(#contains(["amount"], #nat(4)), r);
});

test("not_ inverts the inner predicate", func () {
  let r = row([("active", #bool(true))]);
  assert     Predicate.eval(#not_(#eq(["active"], #bool(false))), r);
  assert not Predicate.eval(#not_(#eq(["active"], #bool(true))),  r);
});

test("compare is a total order on like types", func () {
  assert Predicate.compare(#nat(1),  #nat(2))     == #less;
  assert Predicate.compare(#nat(2),  #nat(2))     == #equal;
  assert Predicate.compare(#nat(3),  #nat(2))     == #greater;
  assert Predicate.compare(#text("a"), #text("b")) == #less;
  assert Predicate.compare(#bool(false), #bool(true)) == #less;
  // null compares equal to null
  assert Predicate.compare(#null_, #null_) == #equal;
});

test("compare bridges nat and int", func () {
  assert Predicate.compare(#nat(5), #int(5))  == #equal;
  assert Predicate.compare(#int(-1), #nat(0)) == #less;
});

test("compare on float-float and float bridges nat/int", func () {
  assert Predicate.compare(#float(1.5), #float(2.0))   == #less;
  assert Predicate.compare(#float(2.0), #float(2.0))   == #equal;
  assert Predicate.compare(#float(3.0), #float(2.0))   == #greater;
  // bridges with Nat / Int so JSON-encoded integer thresholds compare
  // against Float row values directly.
  assert Predicate.compare(#float(2.5), #nat(2))       == #greater;
  assert Predicate.compare(#nat(2),     #float(2.5))   == #less;
  assert Predicate.compare(#float(0.5), #int(1))       == #less;
  assert Predicate.compare(#int(-1),    #float(-0.5))  == #less;
  assert Predicate.compare(#float(5.0), #nat(5))       == #equal;
  assert Predicate.compare(#float(5.0), #int(5))       == #equal;
});

test("Float predicate eval covers comparison + bridging", func () {
  let r = row([("ratio", #float(0.42)), ("temp", #float(-3.5))]);
  assert     Predicate.eval(#lt(["ratio"], #float(1.0)),  r);
  assert     Predicate.eval(#gt(["ratio"], #float(0.0)),  r);
  assert     Predicate.eval(#eq(["ratio"], #float(0.42)), r);
  // Nat threshold against Float row value.
  assert     Predicate.eval(#lt(["ratio"], #nat(1)),      r);
  // Int threshold against Float row value (negative ranges).
  assert     Predicate.eval(#lt(["temp"],  #int(0)),      r);
  assert not Predicate.eval(#gt(["temp"],  #int(0)),      r);
  // in_ matches across Float / Nat element types.
  assert     Predicate.eval(#in_(["ratio"], [#float(0.0), #float(0.42)]), r);
});
