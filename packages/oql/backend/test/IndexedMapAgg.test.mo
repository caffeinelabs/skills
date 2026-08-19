/// Index-served aggregates: `execute()` answers count / min / max / group-count
/// straight off the index stats (no row scan) — this pins that the answer
/// equals a plain-scan aggregate over the same data. Differential: an
/// `IndexedMap` entity (`idx`) vs a plain `Map`-backed entity (`scan`), same
/// rows; every aggregate query must return the same rows. Also checks the
/// fall-back shapes (sum, range/multi-predicate count) still agree.

import { test } "mo:test";
import Nat        "mo:core/Nat";
import Map        "mo:core/Map";
import Array      "mo:core/Array";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Predicate  "../src/Predicate";
import Registry   "../src/Registry";

type E = { id : Nat; status : Text; amount : Nat };

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

let statuses = ["a", "b", "c"];
func mkE(k : Nat) : E = { id = k; status = statuses[k % 3]; amount = (k + 1) * 100 };
func eRow(e : E) : OQL.Entity.Row = [("id", #nat(e.id)), ("status", #text(e.status)), ("amount", #nat(e.amount))];

// idx (IndexedMap) and scan (plain Map) entities over the same `n` rows.
func regs(n : Nat) : (Registry.Registry, Registry.Registry) {
  let rows  = Array.tabulate<E>(n, mkE);
  let plain = Map.empty<Nat, E>();
  let em    = IndexedMap.new<Nat, E>([ ("status", #hash), ("amount", #ordered) ]);
  for (e in rows.values()) { plain.add(Nat.compare, e.id, e); em.put(e.id, e, Nat.compare, eRow) };
  ( Registry.build([ em.entity("e", "E", "id", Nat.compare, eRow).build() ]),
    Registry.build([ Entity.new<E>("e", func () = plain.values(), "E", "id", eRow).build() ]) );
};
let (idx, scan) = regs(6);          // a:{0,3} b:{1,4} c:{2,5}; amounts 100..600
let (idxEmpty, scanEmpty) = regs(0);

// ── order-independent row comparison ────────────────────────────────────────
func valueKey(v : OQL.Value) : Text = switch v {
  case (#null_) { "0" }; case (#bool b) { "1" # (if b "T" else "F") };
  case (#nat n) { "2" # Nat.toText(n) }; case (#int i) { "3" # debug_show(i) };
  case (#float f) { "4" # debug_show(f) }; case (#text t) { "5" # t };
};
func rowKey(row : [Executor.Cell]) : Text {
  var s = "";
  for (c in Array.sort(Array.map<Executor.Cell, Text>(row, func c = c.name # "=" # valueKey(c.value)), Text.compare).values()) { s := s # c # "|" };
  s
};
func sameRows(a : [[Executor.Cell]], b : [[Executor.Cell]]) : Bool {
  if (a.size() != b.size()) return false;
  let ka = Array.sort(Array.map<[Executor.Cell], Text>(a, rowKey), Text.compare);
  let kb = Array.sort(Array.map<[Executor.Cell], Text>(b, rowKey), Text.compare);
  ka == kb
};

func agg(fn : Query.AggFn, field : ?[Text]) : Query.Agg = { fn; field; as_ = null };
func q(where_ : ?Predicate.Predicate, groupBy : [[Text]], aggregate : [Query.Agg], orderBy : [Query.OrderBy]) : Query.Query = {
  start = "e"; where_; groupBy; aggregate; orderBy; offset = null; limit = null; select = null;
};

// idx (index-served) must equal scan, and return `count` rows.
func check(rIdx : Registry.Registry, rScan : Registry.Registry, qq : Query.Query) : [[Executor.Cell]] {
  let i = Executor.runWith(rIdx, qq, unrestricted).rows;
  let s = Executor.runWith(rScan, qq, unrestricted).rows;
  assert sameRows(i, s);
  i
};

test("count(*) → total, off the index (no scan)", func () {
  let r = check(idx, scan, q(null, [], [agg(#count, null)], []));
  assert cell(r[0], "count") == ?(#nat(6));
});

test("count(*) where eq → posting size", func () {
  let r = check(idx, scan, q(?(#eq(["status"], #text("a"))), [], [agg(#count, null)], []));
  assert cell(r[0], "count") == ?(#nat(2));
});

test("count(*) where eq, no match → 0", func () {
  let r = check(idx, scan, q(?(#eq(["status"], #text("zz"))), [], [agg(#count, null)], []));
  assert cell(r[0], "count") == ?(#nat(0));
});

test("min / max off the ordered index", func () {
  assert cell(check(idx, scan, q(null, [], [agg(#min, ?["amount"])], []))[0], "min_amount") == ?(#nat(100));
  assert cell(check(idx, scan, q(null, [], [agg(#max, ?["amount"])], []))[0], "max_amount") == ?(#nat(600));
});

test("groupBy status + count → histogram equals scan", func () {
  let r = check(idx, scan, q(null, [["status"]], [agg(#count, null)], []));
  assert r.size() == 3;   // a, b, c each 2
});

test("groupBy + count, orderBy count then applied by the tail", func () {
  ignore check(idx, scan, q(null, [["status"]], [agg(#count, null)], [{ field = ["count"]; dir = #desc }]));
});

test("empty entity: count → 0, min → null", func () {
  assert cell(check(idxEmpty, scanEmpty, q(null, [], [agg(#count, null)], []))[0], "count") == ?(#nat(0));
  assert cell(check(idxEmpty, scanEmpty, q(null, [], [agg(#min, ?["amount"])], []))[0], "min_amount") == ?(#null_);
});

// A lineariser rendering amount 0 as #null_, so the `amount` index carries a
// real #null_ posting alongside real values — exercises min/max null-skipping.
func eRowN(e : E) : OQL.Entity.Row = [
  ("id", #nat(e.id)), ("status", #text(e.status)),
  ("amount", if (e.amount == 0) #null_ else #nat(e.amount)),
];
func regsN(amounts : [Nat]) : (Registry.Registry, Registry.Registry) {
  let plain = Map.empty<Nat, E>();
  let em = IndexedMap.new<Nat, E>([ ("amount", #ordered) ]);
  var k = 0;
  for (amt in amounts.values()) {
    let e = { id = k; status = "x"; amount = amt };
    plain.add(Nat.compare, k, e); em.put(k, e, Nat.compare, eRowN); k += 1;
  };
  ( Registry.build([ em.entity("e", "E", "id", Nat.compare, eRowN).build() ]),
    Registry.build([ Entity.new<E>("e", func () = plain.values(), "E", "id", eRowN).build() ]) );
};

test("min/max skip a real #null_ posting (mixed nulls)", func () {
  let (i, s) = regsN([0, 300, 100, 0, 500]);   // amounts: null,300,100,null,500
  assert cell(check(i, s, q(null, [], [agg(#min, ?["amount"])], []))[0], "min_amount") == ?(#nat(100));
  assert cell(check(i, s, q(null, [], [agg(#max, ?["amount"])], []))[0], "max_amount") == ?(#nat(500));
});

test("min over an all-null column → null", func () {
  let (i, s) = regsN([0, 0, 0]);
  assert cell(check(i, s, q(null, [], [agg(#min, ?["amount"])], []))[0], "min_amount") == ?(#null_);
});

test("fall-back shapes still agree with scan", func () {
  ignore check(idx, scan, q(null, [], [agg(#sum, ?["amount"])], []));                                   // sum: not index-served
  ignore check(idx, scan, q(?(#ge(["amount"], #nat(300))), [], [agg(#count, null)], []));               // range count: residual
  ignore check(idx, scan, q(?(#and_([#eq(["status"], #text("a")), #ge(["amount"], #nat(200))])), [], [agg(#count, null)], [])); // multi-predicate
  ignore check(idx, scan, q(null, [], [agg(#min, ?["id"])], []));                                       // min on a #hash-only column? id not indexed → scan
});
