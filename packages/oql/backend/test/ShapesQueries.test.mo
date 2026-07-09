/// Correctness guard for the Tier 2 `shapes.bench.mo` queries: confirms the
/// dotted-path edge joins (R3/R4/R5) actually resolve to real data, so the
/// benchmark measures real joined work — not silently-empty results from a
/// left-join-to-null. Pure (`Executor.runWith`), so it runs in the
/// interpreter; uses a small fixture for predictable assertions.
///
/// Mirrors the bench's schema (`order.customerId -> customer`); query shapes
/// match `shapes.bench.mo` (thresholds scaled to the small fixture).

import { test } "mo:test";
import Array    "mo:core/Array";
import Nat      "mo:core/Nat";
import OQL      "../src";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

type Customer = { id : Nat; name : Text; country : Text; age : Nat; vip : Bool };
type Order    = { id : Nat; customerId : Nat; amount : Nat; paid : Bool };

let countries = ["DE", "UK", "FR", "US"];

func cRow(c : Customer) : OQL.Entity.Row = [
  ("id", #nat(c.id)), ("name", #text(c.name)), ("country", #text(c.country)),
  ("age", #nat(c.age)), ("vip", #bool(c.vip)),
];
func oRow(o : Order) : OQL.Entity.Row = [
  ("id", #nat(o.id)), ("customerId", #nat(o.customerId)),
  ("amount", #nat(o.amount)), ("paid", #bool(o.paid)),
];

let CC = 8;   // customers
let NO = 40;  // orders
let custs = Array.tabulate<Customer>(CC, func k = {
  id = k; name = "customer_" # Nat.toText(k); country = countries[k % 4];
  age = 20 + k % 50; vip = (k % 5 == 0);
});
let ords = Array.tabulate<Order>(NO, func k = {
  id = k; customerId = k % CC; amount = k; paid = (k % 2 == 0);
});
let reg = Registry.build([
  OQL.Entity.new<Customer>("customer", func () = custs.values(), "Customer", "id", cRow).build(),
  OQL.Entity.new<Order>("order", func () = ords.values(), "Order", "id", oRow)
    .edge("customerId", "customer").build(),
]);
let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;
func order() : Query.Query = {
  start = "order"; where_ = null; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select = null;
};
func run(q : Query.Query) : Executor.Result = Executor.runWith(reg, q, unrestricted);
func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null;
};
func isText(v : ?OQL.Value) : Bool = switch v { case (?#text _) true; case _ false };

// R1 — filter + paginate, no sort. 20 of 40 orders are unpaid; limit 25 -> 20,
// and every returned row must actually be unpaid.
test("R1 filter+page returns exactly the unpaid rows", func () {
  let r = run({ order() with where_ = ?(#eq(["paid"], #bool(false))); limit = ?25 });
  assert r.rows.size() == 20;
  for (row in r.rows.values()) { assert cell(row, "paid") == ?(#bool(false)) };
});

// R2 — filter + orderBy + limit. amount >= 20 -> ids 20..39 (20 rows); strictly
// descending by amount, top is 39, and every row satisfies the filter.
test("R2 filter+sort+limit: descending, all match the filter", func () {
  let r = run({ order() with where_ = ?(#ge(["amount"], #nat(20)));
                orderBy = [{ field = ["amount"]; dir = #desc }]; limit = ?25 });
  assert r.rows.size() == 20;
  assert cell(r.rows[0], "amount") == ?(#nat(39));
  var prev = 40;  // above the max amount (39)
  for (row in r.rows.values()) {
    switch (cell(row, "amount")) {
      case (?#nat(a)) { assert a >= 20; assert a <= prev; prev := a };
      case _ { assert false };
    };
  };
});

// R3 — orderBy on a dotted edge path. The bench's R3 sorts by `customerId.name`
// with the default projection; here we also `select` that path so we can
// inspect it directly — proving the sort key (and thus the join) resolves and
// the rows come out ordered by the traversed name.
test("R3 edge-sort resolves the join and orders by the traversed name", func () {
  let r = run({ order() with orderBy = [{ field = ["customerId", "name"]; dir = #asc }];
                limit = ?25; select = ?[["id"], ["customerId", "name"]] });
  assert r.rows.size() == 25;
  assert isText(cell(r.rows[0], "customerId.name"));   // join resolved -> real name
  // ascending by the traversed name
  var prev = "";
  for (row in r.rows.values()) {
    switch (cell(row, "customerId.name")) {
      case (?#text(n)) { assert n >= prev; prev := n };
      case _ { assert false };
    };
  };
});

// Decorate-sort must be STABLE: many orders share a customer (customerId =
// id % CC), so `customerId.name` ties across them. A stable sort keeps
// equal-key rows in input (scan) order. Orders for customer_0 are at scan
// positions 0,8,16,24,32 — they must come out in that ascending id order.
test("edge-sort is stable: equal keys keep input order", func () {
  let r = run({ order() with orderBy = [{ field = ["customerId", "name"]; dir = #asc }];
                select = ?[["id"], ["customerId", "name"]] });
  assert r.rows.size() == NO;
  var prevId = 0;
  var seen = 0;
  for (row in r.rows.values()) {
    if (cell(row, "customerId.name") == ?(#text("customer_0"))) {
      switch (cell(row, "id")) {
        case (?#nat(id)) { if (seen > 0) { assert id > prevId }; prevId := id; seen += 1 };
        case _ { assert false };
      };
    };
  };
  assert seen == 5;   // ids 0, 8, 16, 24, 32, in order
});

// R4 — groupBy a dotted edge key + aggregate. The fixture is uniform: each of
// the 4 countries has 2 of 8 customerIds, each hit by 40/8 = 5 orders -> 10
// orders/country. Exact count AND sum per country are checked against the
// hand-computed source totals (regardless of group order).
func expectedFor(country : Text) : (Nat, Nat) = switch country {
  case "DE" { (10, 180) };  // ids with id%8 in {0,4}
  case "UK" { (10, 190) };  //                  {1,5}
  case "FR" { (10, 200) };  //                  {2,6}
  case "US" { (10, 210) };  //                  {3,7}
  case _    { (0, 0) };
};
test("R4 groupBy edge + aggregate: exact count and sum per country", func () {
  let r = run({ order() with groupBy = [["customerId", "country"]];
                aggregate = [{ fn = #count; field = null; as_ = null },
                             { fn = #sum; field = ?["amount"]; as_ = null }] });
  assert r.rows.size() == 4;
  for (row in r.rows.values()) {
    switch (cell(row, "customerId.country")) {
      case (?#text(c)) {
        let (ec, es) = expectedFor(c);
        assert ec != 0;                               // a known country
        assert cell(row, "count") == ?(#nat(ec));
        assert cell(row, "sum_amount") == ?(#nat(es));
      };
      case _ { assert false };
    };
  };
});

// R5 — join filter + project. Orders whose customer.country == "DE". For order
// `id`, customerId = id%8, so the join must resolve to *that* customer:
// name == "customer_<id%8>" and country == "DE". This catches a mis-join (right
// shape, wrong row), not just a null.
test("R5 join filter+project: joined fields match the source customer", func () {
  let r = run({ order() with where_ = ?(#eq(["customerId", "country"], #text("DE")));
                select = ?[["id"], ["customerId", "name"], ["customerId", "country"]] });
  assert r.rows.size() == 10;
  for (row in r.rows.values()) {
    switch (cell(row, "id")) {
      case (?#nat(id)) {
        assert cell(row, "customerId.name") == ?(#text("customer_" # Nat.toText(id % CC)));
        assert cell(row, "customerId.country") == ?(#text("DE"));
      };
      case _ { assert false };
    };
  };
});

// ── Nat<->Int join bridge ─────────────────────────────────────────────────
// The PK index is keyed on `Value` via `Predicate.compare`, which bridges
// `#nat`/`#int`. A Nat FK must join an Int PK of the same value (and vice
// versa), or the join silently left-joins to null. Predicate-level bridging is
// covered in Predicate.test.mo; these lock it at the join level.

type NatPk = { id : Nat; tag : Text };
type IntPk = { id : Int; tag : Text };
type OrderI = { id : Nat; custId : Int };   // Int FK -> Nat PK
type OrderN = { id : Nat; custId : Nat };   // Nat FK -> Int PK

func natPkRow(r : NatPk) : OQL.Entity.Row = [("id", #nat(r.id)), ("tag", #text(r.tag))];
func intPkRow(r : IntPk) : OQL.Entity.Row = [("id", #int(r.id)), ("tag", #text(r.tag))];
func orderIRow(o : OrderI) : OQL.Entity.Row = [("id", #nat(o.id)), ("custId", #int(o.custId))];
func orderNRow(o : OrderN) : OQL.Entity.Row = [("id", #nat(o.id)), ("custId", #nat(o.custId))];

let natPks = Array.tabulate<NatPk>(3, func k = { id = k; tag = "n" # Nat.toText(k) });
let intPks = Array.tabulate<IntPk>(3, func k = { id = k; tag = "i" # Nat.toText(k) });
let ordsI = Array.tabulate<OrderI>(3, func k = { id = k; custId = k });
let ordsN = Array.tabulate<OrderN>(3, func k = { id = k; custId = k });

let regI2N = Registry.build([
  OQL.Entity.new<NatPk>("natpk", func () = natPks.values(), "NatPk", "id", natPkRow).build(),
  OQL.Entity.new<OrderI>("ordI", func () = ordsI.values(), "OrderI", "id", orderIRow)
    .edge("custId", "natpk").build(),
]);
let regN2I = Registry.build([
  OQL.Entity.new<IntPk>("intpk", func () = intPks.values(), "IntPk", "id", intPkRow).build(),
  OQL.Entity.new<OrderN>("ordN", func () = ordsN.values(), "OrderN", "id", orderNRow)
    .edge("custId", "intpk").build(),
]);

func joinQuery(start : Text, edge : Text) : Query.Query = {
  start; where_ = null; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select = ?[["id"], [edge, "tag"]];
};

test("join bridges Int FK to Nat PK", func () {
  let r = Executor.runWith(regI2N, joinQuery("ordI", "custId"), unrestricted);
  assert r.rows.size() == 3;
  for (row in r.rows.values()) {
    switch (cell(row, "id"), cell(row, "custId.tag")) {
      case (?#nat(id), ?#text(l)) { assert l == ("n" # Nat.toText(id)) };
      case _ { assert false };
    };
  };
});

test("join bridges Nat FK to Int PK", func () {
  let r = Executor.runWith(regN2I, joinQuery("ordN", "custId"), unrestricted);
  assert r.rows.size() == 3;
  for (row in r.rows.values()) {
    switch (cell(row, "id"), cell(row, "custId.tag")) {
      case (?#nat(id), ?#text(l)) { assert l == ("i" # Nat.toText(id)) };
      case _ { assert false };
    };
  };
});

test("dangling FK left-joins to null", func () {
  let dangling = [{ id = 0; custId = 99 : Int }];
  let regD = Registry.build([
    OQL.Entity.new<NatPk>("natpk", func () = natPks.values(), "NatPk", "id", natPkRow).build(),
    OQL.Entity.new<OrderI>("ordI", func () = dangling.values(), "OrderI", "id", orderIRow)
      .edge("custId", "natpk").build(),
  ]);
  let r = Executor.runWith(regD, joinQuery("ordI", "custId"), unrestricted);
  assert r.rows.size() == 1;
  assert cell(r.rows[0], "custId.tag") == ?(#null_);   // dangling FK -> left-join null
});

// ── Float-valued FK is unjoinable at runtime ─────────────────────────────
// A declared-Float FK is rejected at plan time by `validateHop`'s `joinable`
// type check, so it never reaches the probe. This covers the divergence case:
// the seed (first) row emits #nat, so the plan-time check sees "Nat" and passes,
// but a later row emits #float for the same FK. That #float reaches the probe,
// where `joinableValue` must reject it (left-join null) rather than let
// Predicate.compare bridge #float 2.0 into the numerically-equal #nat 2 PK.

type OrderMix = { id : Nat; custId : Nat };
func orderMixRow(o : OrderMix) : OQL.Entity.Row = [
  ("id", #nat(o.id)),
  ("custId", if (o.id == 2) #float(2.0) else #nat(o.custId)),
];
let ordsMix = [{ id = 0; custId = 0 }, { id = 1; custId = 1 }, { id = 2; custId = 2 }];

let regMix = Registry.build([
  OQL.Entity.new<NatPk>("natpk", func () = natPks.values(), "NatPk", "id", natPkRow).build(),
  OQL.Entity.new<OrderMix>("ordMix", func () = ordsMix.values(), "OrderMix", "id", orderMixRow)
    .edge("custId", "natpk").build(),
]);

test("float-valued FK left-joins to null (seed was Nat)", func () {
  let r = Executor.runWith(regMix, joinQuery("ordMix", "custId"), unrestricted);
  assert r.rows.size() == 3;
  assert cell(r.rows[0], "custId.tag") == ?(#text "n0");   // Nat FK -> joins
  assert cell(r.rows[1], "custId.tag") == ?(#text "n1");   // Nat FK -> joins
  assert cell(r.rows[2], "custId.tag") == ?(#null_);       // Float FK -> unjoinable -> null
});
