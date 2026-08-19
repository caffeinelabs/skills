/// End-to-end: an `IndexedMap` participates in OQL querying via `.entity()`.
/// The inner map is encapsulated, so `.entity()` is the ONLY bridge from an
/// IndexedMap into a `Registry` — this is how an app exposes indexed storage to
/// `schema()` / `execute()` (and the Data-Intelligence agent).
///
/// `.entity()` attaches a `served` capability, so the executor's planner routes
/// sargable queries through the live index. Correctness follows SQL semantics:
/// a plan yields a SUPERSET the residual `where_` narrows, an explicit `orderBy`
/// is honoured, and without one the row order (and which rows a bare `limit`
/// keeps) is unspecified. So the oracle here is NOT "served == scan byte for
/// byte" — it is the contract the planner must satisfy against the plain-scan
/// entity as ground truth:
///   - every served row is a real match (⊆ the full unbounded scan result),
///   - the count matches the scan (== |matches|, or min(limit, |matches|)),
///   - with no limit the multiset equals the full match set exactly,
///   - with an `orderBy` the served rows are correctly ordered.

import { test } "mo:test";
import Nat        "mo:core/Nat";
import Int        "mo:core/Int";
import Float      "mo:core/Float";
import Bool       "mo:core/Bool";
import Text       "mo:core/Text";
import Array      "mo:core/Array";
import Map        "mo:core/Map";
import Option     "mo:core/Option";
import Order      "mo:core/Order";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Predicate  "../src/Predicate";
import Registry   "../src/Registry";

type User = { id : Nat; email : Text; age : Nat; kind : Text };

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

// Same live data behind both registries: one index-served, one plain scan.
// Ages are distinct, so `orderBy age` + `limit` has a unique answer; `kind`
// repeats (reg×3 / vip×3) to exercise `#eq` / `#in_` multiplicity.
let users = IndexedMap.new<Nat, User>([ ("email", #hash), ("age", #ordered), ("kind", #hash) ]);
users.put(1, { id = 1; email = "a@x"; age = 30; kind = "reg" });
users.put(2, { id = 2; email = "b@x"; age = 17; kind = "vip" });
users.put(3, { id = 3; email = "c@x"; age = 42; kind = "reg" });
users.put(4, { id = 4; email = "d@x"; age = 25; kind = "vip" });
users.put(5, { id = 5; email = "e@x"; age = 51; kind = "reg" });
users.put(6, { id = 6; email = "f@x"; age = 38; kind = "vip" });

let servedReg = Registry.build([ users.entity("user", "User", "id").build() ]);
let scanReg   = Registry.build([ Entity.new<User>("user", func () = users.values(), "User", "id").build() ]);

// ── comparison machinery ───────────────────────────────────────────────────

func valueKey(v : OQL.Value) : Text = switch v {
  case (#null_)   { "0" };
  case (#bool b)  { "1" # Bool.toText(b) };
  case (#nat n)   { "2" # Nat.toText(n) };
  case (#int i)   { "3" # Int.toText(i) };
  case (#float f) { "4" # Float.toText(f) };
  case (#text t)  { "5" # t };
};

// Order-independent identity of a row: its cells as name=value, name-sorted.
func rowKey(row : [Executor.Cell]) : Text {
  let parts = Array.map<Executor.Cell, Text>(row, func c = c.name # "=" # valueKey(c.value));
  var s = "";
  for (p in Array.sort(parts, Text.compare).values()) { s := s # p # "|" };
  s
};

func bag(rows : [[Executor.Cell]]) : Map.Map<Text, Nat> {
  let m = Map.empty<Text, Nat>();
  for (r in rows.values()) {
    let k = rowKey(r);
    m.add(Text.compare, k, 1 + Option.get(m.get(Text.compare, k), 0));
  };
  m
};

func flip(o : Order.Order) : Order.Order = switch o { case (#less) #greater; case (#equal) #equal; case (#greater) #less };

func cmpKeys(a : [Executor.Cell], b : [Executor.Cell], clauses : [Query.OrderBy]) : Order.Order {
  for (cl in clauses.values()) {
    let va = Option.get(cell(a, cl.field[0]), #null_);
    let vb = Option.get(cell(b, cl.field[0]), #null_);
    let raw = Predicate.compare(va, vb);
    let oriented = switch (cl.dir) { case (#asc) raw; case (#desc) flip(raw) };
    if (oriented != #equal) return oriented;
  };
  #equal
};

// The planner's SQL-semantics contract, with the plain-scan entity as truth.
func check(q : Query.Query) : [[Executor.Cell]] {
  let served = Executor.runWith(servedReg, q, unrestricted).rows;
  let scan   = Executor.runWith(scanReg, q, unrestricted).rows;
  // Full (unbounded) match set — order-independent ground truth.
  let full   = Executor.runWith(scanReg, { q with limit = null; offset = null }, unrestricted).rows;

  assert served.size() == scan.size();                       // same count semantics

  let fullBag   = bag(full);
  let servedBag = bag(served);
  // Residual correctness: every served row is a genuine match.
  for ((k, c) in servedBag.entries()) { assert c <= Option.get(fullBag.get(Text.compare, k), 0) };
  // Unbounded ⇒ exactly the full match set.
  if (q.limit == null and q.offset == null) {
    assert servedBag.size() == fullBag.size();
    for ((k, c) in servedBag.entries()) { assert ?c == fullBag.get(Text.compare, k) };
  };
  // Ordered ⇒ served rows respect the orderBy.
  if (q.orderBy.size() > 0) {
    var i = 1;
    while (i < served.size()) { assert cmpKeys(served[i - 1], served[i], q.orderBy) != #greater; i += 1 };
  };
  served
};

func q(where_ : ?Predicate.Predicate, orderBy : [Query.OrderBy], limit : ?Nat) : Query.Query = {
  start = "user"; where_; groupBy = []; aggregate = [];
  orderBy; offset = null; limit; select = null;
};

// ── point / equality ────────────────────────────────────────────────────────

test("#eq on #hash (email) → point probe", func () {
  assert check(q(?(#eq(["email"], #text("c@x"))), [], null)).size() == 1;
});

test("#eq on #ordered (age) → point probe", func () {
  assert check(q(?(#eq(["age"], #nat(42))), [], null)).size() == 1;
});

// ── #in_ (now served) ────────────────────────────────────────────────────────

test("#in_ on #hash (kind) → union of point probes", func () {
  assert check(q(?(#in_(["kind"], [#text("vip")])), [], null)).size() == 3;
});

test("#in_ on #ordered (age) → union of point probes", func () {
  assert check(q(?(#in_(["age"], [#nat(30), #nat(42), #nat(51)])), [], null)).size() == 3;
});

test("#in_ empty set matches nothing", func () {
  assert check(q(?(#in_(["kind"], [])), [], null)).size() == 0;
});

// ── ranges (now served) ──────────────────────────────────────────────────────

test("bare range #ge (no orderBy) → unordered superset, residual-filtered", func () {
  assert check(q(?(#ge(["age"], #nat(30))), [], null)).size() == 4;   // 30,42,51,38
});

test("range #ge + orderBy age asc → seek + ordered", func () {
  let r = check(q(?(#ge(["age"], #nat(30))), [{ field = ["age"]; dir = #asc }], null));
  assert r.size() == 4;
  assert cell(r[0], "age") == ?(#nat(30));
});

test("bounded range (and_ ge/le) + orderBy age desc", func () {
  let r = check(q(?(#and_([#ge(["age"], #nat(25)), #le(["age"], #nat(42))])), [{ field = ["age"]; dir = #desc }], null));
  assert r.size() == 4;                               // 25,30,38,42
  assert cell(r[0], "age") == ?(#nat(42));
});

test("bare range + limit → some N valid matches (order unspecified)", func () {
  assert check(q(?(#ge(["age"], #nat(30))), [], ?2)).size() == 2;
});

// ── orderBy / top-N ──────────────────────────────────────────────────────────

test("orderBy age desc + limit 3 (top-N)", func () {
  let r = check(q(null, [{ field = ["age"]; dir = #desc }], ?3));
  assert r.size() == 3;
  assert cell(r[0], "age") == ?(#nat(51));
  assert cell(r[2], "age") == ?(#nat(38));
});

test("#eq drives, executor sorts the superset by a second column", func () {
  let r = check(q(?(#eq(["kind"], #text("reg"))), [{ field = ["age"]; dir = #desc }], null));
  assert r.size() == 3;                               // reg: 30,42,51
  assert cell(r[0], "age") == ?(#nat(51));
});

// ── aggregation over a served range (order-irrelevant) ───────────────────────

test("count over a served range", func () {
  let r = Executor.runWith(servedReg, {
    start = "user"; where_ = ?(#ge(["age"], #nat(30)));
    groupBy = []; aggregate = [{ fn = #count; field = null; as_ = null }];
    orderBy = []; offset = null; limit = null; select = null;
  }, unrestricted).rows;
  assert r.size() == 1;
  assert cell(r[0], "count") == ?(#nat(4));
});

// ── fallback + liveness ──────────────────────────────────────────────────────

test("un-servable predicate falls back to scan and stays correct", func () {
  assert check(q(?(#eq(["id"], #nat(2))), [], null)).size() == 1;          // id not indexed
  assert check(q(?(#startsWith(["email"], #text("a"))), [], null)).size() == 1;
});

test("writes flow through to the next served query", func () {
  users.put(7, { id = 7; email = "g@x"; age = 60; kind = "reg" });
  let r = check(q(?(#ge(["age"], #nat(30))), [{ field = ["age"]; dir = #desc }], null));
  assert r.size() == 5;                               // + age 60
  assert cell(r[0], "age") == ?(#nat(60));
});
