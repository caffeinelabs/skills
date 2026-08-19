/// Pins the planner's range behaviour on a `#hash`-declared column.
///
/// `planServed`'s bare-range shape (`findRangeCol`) and its bound pushdown
/// (`boundsFor`) gate on `kindOf(col) != null`, NOT on `== #ordered` — so a
/// range predicate on a `#hash` column IS served from the index via
/// `Served.range`. Today that is correct because a `#hash` index shares the
/// same ordered `Map` store as `#ordered` (`SecondaryIndex.Kind` only advises
/// the planner). But if `#hash` ever becomes a real hash table, `range` on it
/// can no longer stream the full key interval, and a served range would
/// silently UNDER-FETCH in production.
///
/// This suite pins that boundary: it runs range, boundary, and orderBy
/// queries on a `#hash` column THROUGH the real executor path, against an
/// index-served entity and a plain-scan entity over the same live rows, and
/// asserts identical results — so if `#hash` gains a non-ordered backing
/// store, these tests fail loudly instead of production under-fetching
/// silently. `kindOf` itself is pinned to `?#hash`, so an intentional
/// reclassification of the column's kind is visible too.
///
/// Oracle (the IndexedMapEntity.test.mo contract): count parity with the
/// scan, served ⊆ full matches, exact multiset without limit/offset, ordered
/// when `orderBy` is present — plus row-for-row equality with the scan when a
/// TOTAL `orderBy` (ties broken by id) makes the result order unique.

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

type Item = { id : Nat; score : Nat; tag : Text };

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

// `score` declared `#hash` — the shape at risk. Duplicated key (20) so
// boundary strictness is observable; ids are distinct so `orderBy [score, id]`
// is total and sequences can be compared row-for-row.
let items = IndexedMap.new<Nat, Item>([ ("score", #hash) ]);
items.put(1, { id = 1; score = 10; tag = "a" });
items.put(2, { id = 2; score = 20; tag = "b" });
items.put(3, { id = 3; score = 20; tag = "c" });   // duplicate key
items.put(4, { id = 4; score = 30; tag = "d" });
items.put(5, { id = 5; score = 40; tag = "e" });
items.put(6, { id = 6; score = 50; tag = "f" });

let servedDecl = items.entity("item", "Item", "id").build();
let servedReg  = Registry.build([ servedDecl ]);
let scanReg    = Registry.build([ Entity.new<Item>("item", func () = items.values(), "Item", "id").build() ]);

// ── comparison machinery (as in IndexedMapEntity.test.mo) ──────────────────

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
func check(qq : Query.Query) : [[Executor.Cell]] {
  let served = Executor.runWith(servedReg, qq, unrestricted).rows;
  let scan   = Executor.runWith(scanReg, qq, unrestricted).rows;
  // Full (unbounded) match set — order-independent ground truth.
  let full   = Executor.runWith(scanReg, { qq with limit = null; offset = null }, unrestricted).rows;

  assert served.size() == scan.size();                       // same count semantics

  let fullBag   = bag(full);
  let servedBag = bag(served);
  // Residual correctness: every served row is a genuine match — a #hash range
  // that OVER-fetched would surface junk here.
  for ((k, c) in servedBag.entries()) { assert c <= Option.get(fullBag.get(Text.compare, k), 0) };
  // Unbounded ⇒ exactly the full match set — a #hash range that UNDER-fetched
  // (the silent-production failure this file exists to catch) fails here.
  if (qq.limit == null and qq.offset == null) {
    assert servedBag.size() == fullBag.size();
    for ((k, c) in servedBag.entries()) { assert ?c == fullBag.get(Text.compare, k) };
  };
  // Ordered ⇒ served rows respect the orderBy.
  if (qq.orderBy.size() > 0) {
    var i = 1;
    while (i < served.size()) { assert cmpKeys(served[i - 1], served[i], qq.orderBy) != #greater; i += 1 };
  };
  served
};

// With a TOTAL orderBy (ties broken by id) the result order is unique, so
// served and scan must agree row-for-row, not just as a multiset.
func checkExact(qq : Query.Query) : [[Executor.Cell]] {
  let served = check(qq);
  let scan   = Executor.runWith(scanReg, qq, unrestricted).rows;
  assert Array.map<[Executor.Cell], Text>(served, rowKey)
      == Array.map<[Executor.Cell], Text>(scan, rowKey);
  served
};

func q(where_ : ?Predicate.Predicate, orderBy : [Query.OrderBy], limit : ?Nat) : Query.Query = {
  start = "item"; where_; groupBy = []; aggregate = [];
  orderBy; offset = null; limit; select = null;
};

// ── the gate itself ─────────────────────────────────────────────────────────

test("kindOf pins the declared #hash kind — a reclassification is visible", func () {
  switch (servedDecl.served) {
    case (?s) {
      // The planner's range shapes fire because this is non-null; the orderBy
      // shape does NOT because it isn't #ordered. If #hash stops sharing the
      // ordered store, this pin forces the change to be deliberate.
      assert s.kindOf("score") == ?#hash;
      assert s.kindOf("id")    == null;   // unindexed columns stay outside the gate
      assert s.kindOf("tag") == null;
    };
    case null { assert false };  // IndexedMap.entity always attaches `served`
  };
});

// ── ranges served from the #hash column ─────────────────────────────────────

test("bare #ge range on a #hash column equals the scan", func () {
  assert check(q(?(#ge(["score"], #nat(20))), [], null)).size() == 5;   // 20,20,30,40,50
});

test("strict #gt drops the duplicated boundary key on both sides", func () {
  assert check(q(?(#gt(["score"], #nat(20))), [], null)).size() == 3;   // 30,40,50
});

test("strict #lt upper bound equals the scan", func () {
  assert check(q(?(#lt(["score"], #nat(30))), [], null)).size() == 3;   // 10,20,20
});

test("#le inclusive at a duplicated key equals the scan", func () {
  assert check(q(?(#le(["score"], #nat(20))), [], null)).size() == 3;   // 10,20,20
});

test("bounded window and_(#ge, #lt) equals the scan", func () {
  assert check(q(?(#and_([#ge(["score"], #nat(20)), #lt(["score"], #nat(40))])), [], null)).size() == 3;  // 20,20,30
});

test("bounded window and_(#gt, #le) equals the scan", func () {
  assert check(q(?(#and_([#gt(["score"], #nat(10)), #le(["score"], #nat(40))])), [], null)).size() == 4;  // 20,20,30,40
});

test("empty ranges match nothing on both sides", func () {
  assert check(q(?(#gt(["score"], #nat(50))), [], null)).size() == 0;
  assert check(q(?(#lt(["score"], #nat(10))), [], null)).size() == 0;
});

test("bounds beyond the key space still yield every row", func () {
  assert check(q(?(#ge(["score"], #nat(0))),   [], null)).size() == 6;
  assert check(q(?(#le(["score"], #nat(999))), [], null)).size() == 6;
});

// ── mixed numeric encodings against the #hash index ─────────────────────────

test("#eq with an #int-encoded key probes the #nat-keyed postings", func () {
  assert check(q(?(#eq(["score"], #int(20))), [], null)).size() == 2;
});

test("#ge with an #int-encoded bound seeks the #nat-keyed store", func () {
  assert check(q(?(#ge(["score"], #int(20))), [], null)).size() == 5;
});

test("#in_ with duplicate + mixed-encoding keys does not double-count", func () {
  // [#nat 20, #int 20, #nat 20] must collapse to ONE probe of the key-20
  // posting set: exactly the two score-20 rows, each once.
  assert check(q(?(#in_(["score"], [#nat(20), #int(20), #nat(20)])), [], null)).size() == 2;
});

// ── orderBy interaction (the #ordered-only shape must NOT claim order) ──────

test("range + total orderBy asc is row-for-row equal to the scan", func () {
  let r = checkExact(q(?(#ge(["score"], #nat(20))),
    [ { field = ["score"]; dir = #asc }, { field = ["id"]; dir = #asc } ], null));
  assert r.size() == 5;
  assert cell(r[0], "score") == ?(#nat(20));
  assert cell(r[4], "score") == ?(#nat(50));
});

test("bounded range + total orderBy desc is row-for-row equal to the scan", func () {
  let r = checkExact(q(?(#and_([#ge(["score"], #nat(20)), #le(["score"], #nat(40))])),
    [ { field = ["score"]; dir = #desc }, { field = ["id"]; dir = #desc } ], null));
  assert r.size() == 4;                                    // 40,30,20,20
  assert cell(r[0], "score") == ?(#nat(40));
  assert cell(r[3], "score") == ?(#nat(20));
});

test("orderBy alone on a #hash column is not index-ordered — still correct", func () {
  // kindOf != #ordered keeps the top-N shape off; the executor must sort.
  let r = checkExact(q(null,
    [ { field = ["score"]; dir = #asc }, { field = ["id"]; dir = #asc } ], null));
  assert r.size() == 6;
  assert cell(r[0], "score") == ?(#nat(10));
  assert cell(r[5], "score") == ?(#nat(50));
});

test("top-N: orderBy desc + limit over the #hash column equals the scan", func () {
  let r = checkExact(q(null,
    [ { field = ["score"]; dir = #desc }, { field = ["id"]; dir = #desc } ], ?3));
  assert r.size() == 3;
  assert cell(r[0], "score") == ?(#nat(50));
  assert cell(r[2], "score") == ?(#nat(30));
});

test("bare range + limit keeps count semantics (order unspecified)", func () {
  assert check(q(?(#ge(["score"], #nat(20))), [], ?2)).size() == 2;
});
