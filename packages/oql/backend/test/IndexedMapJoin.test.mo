/// Join-aware planning: a filter on a column *behind an edge* (`edge.col = v`)
/// is served by a semi-join — resolve the target rows matching `col = v`, then
/// drive the start through an `#in_` on the foreign-key index — instead of
/// scanning every start row. Verified differentially: the join-served `order`
/// entity (an `IndexedMap` with `customerId` indexed + a `customer` edge) must
/// return the same rows as a plain-scan `order` entity over the same data.

import { test } "mo:test";
import Nat        "mo:core/Nat";
import Array      "mo:core/Array";
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

type Customer = { id : Nat; country : Text };
type Order    = { id : Nat; customerId : Nat; amount : Nat };

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

let custs : [Customer] = [
  { id = 1; country = "DE" }, { id = 2; country = "UK" },
  { id = 3; country = "DE" }, { id = 4; country = "FR" },
];

// `customerId` indexed (the FK the semi-join drives); `amount` deliberately NOT
// indexed, so a query filtering on it can't be served own-column and must go
// through the join path with `amount` as a residual.
let orders = IndexedMap.new<Nat, Order>([ ("customerId", #hash) ]);
orders.put(10, { id = 10; customerId = 1; amount = 100 });   // DE
orders.put(11, { id = 11; customerId = 2; amount = 200 });   // UK
orders.put(12, { id = 12; customerId = 1; amount = 300 });   // DE
orders.put(13, { id = 13; customerId = 3; amount = 400 });   // DE
orders.put(14, { id = 14; customerId = 4; amount = 500 });   // FR
orders.put(15, { id = 15; customerId = 2; amount = 600 });   // UK

// `customer` is a plain dimension in both registries; only `order` differs.
let customerE = Entity.new<Customer>("customer", func () = custs.values(), "Customer", "id").build();
let idxReg  = Registry.build([ customerE, orders.entity("order", "Order", "id").edge("customerId", "customer").build() ]);
let scanReg = Registry.build([ customerE, Entity.new<Order>("order", func () = orders.values(), "Order", "id").edge("customerId", "customer").build() ]);

func orderIds(reg : Registry.Registry, q : Query.Query) : [Nat] {
  let rows = Executor.runWith(reg, q, unrestricted).rows;
  let ns = Array.map<[Executor.Cell], Nat>(rows, func r = switch (cell(r, "id")) { case (?#nat n) { n }; case _ { 0 } });
  Array.sort(ns, Nat.compare)
};

func q(where_ : ?Predicate.Predicate) : Query.Query = {
  start = "order"; where_; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select = null;
};

// idx (join-served) must equal scan, and equal the hand-computed expectation.
func check(where_ : ?Predicate.Predicate, expected : [Nat]) {
  let idx  = orderIds(idxReg, q(where_));
  let scan = orderIds(scanReg, q(where_));
  assert idx == scan;
  assert idx == expected;
};

test("edge-eq filter is served by the semi-join (customerId.country = DE)", func () {
  check(?(#eq(["customerId", "country"], #text("DE"))), [10, 12, 13]);
});

test("semi-join + residual on a non-indexed own column (amount)", func () {
  check(?(#and_([#eq(["customerId", "country"], #text("DE")), #ge(["amount"], #nat(350))])), [13]);
});

test("edge-eq with no matching target rows → empty", func () {
  check(?(#eq(["customerId", "country"], #text("XX"))), []);
});

test("edge-#in_ filter is served by the semi-join (country in {DE,FR})", func () {
  check(?(#in_(["customerId", "country"], [#text("DE"), #text("FR")])), [10, 12, 13, 14]);
});

test("edge-range filter is served by the semi-join (country >= UK)", func () {
  // UK, and nothing sorts after it here except UK itself → customers 2 (UK).
  check(?(#ge(["customerId", "country"], #text("UK"))), [11, 15]);
});

test("edge-range + residual on a non-indexed own column", func () {
  // every country >= "DE" here, so `amount <= 300` is the effective filter.
  check(?(#and_([#ge(["customerId", "country"], #text("DE")), #le(["amount"], #nat(300))])), [10, 11, 12]);
});

test("own-column #eq on the FK still uses the point index, not the join", func () {
  check(?(#eq(["customerId"], #nat(1))), [10, 12]);
});

test("select can still project across the edge on join-served rows", func () {
  let r = Executor.runWith(idxReg, {
    q(?(#eq(["customerId", "country"], #text("DE")))) with
    select = ?[["id"], ["customerId", "country"]]
  }, unrestricted).rows;
  assert r.size() == 3;
  for (row in r.values()) { assert cell(row, "customerId.country") == ?(#text("DE")) };
});
