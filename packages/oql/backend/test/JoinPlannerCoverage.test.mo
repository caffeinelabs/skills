/// Differential coverage for the semi-join planner (`Executor.planJoin`) —
/// exactly the cases its correctness argument relies on:
///
///   • a DANGLING FK: a start row whose edge points at a missing target must
///     never be admitted by an `=`/`in`/range filter on `edge.col` (left-join
///     null admits none of them), yet must still appear for queries that do
///     not filter on the edge;
///   • a DENIED and a SCOPED join target: an edge into an entity the caller
///     cannot (fully) read contributes empty / only the subject's rows — the
///     semi-join must match the scan's left-join-null behaviour exactly, with
///     no leak;
///   • aggregation over a semi-join-served query: group sets and aggregate
///     values equal the scan's;
///   • an `#in_` edge filter with duplicate + mixed-encoding keys
///     (`[#nat n, #int n]`): no double-counting through the semi-join.
///
/// Routing is PROVEN, not assumed: `probeReg` holds an `order` entity whose
/// scan source is EMPTY but whose served FK index carries the real rows (the
/// builder's `source` swapped for `Iter.empty` after `.entity(...)`, with a
/// `.sample` seeding the schema). A bare query against it returns nothing, so
/// a non-empty edge-filtered result equal to the scan's is positive proof the
/// semi-join path fired for that shape.
///
/// Authorization is driven by injecting `access` resolvers into
/// `Executor.runWith` — the sync analogue of the Expose.test.mo levels, as in
/// Scope.test.mo. The start entity stays unrestricted throughout (a scoped
/// start never plans); only the join target's access varies.

import { test } "mo:test";
import Nat        "mo:core/Nat";
import Int        "mo:core/Int";
import Float      "mo:core/Float";
import Bool       "mo:core/Bool";
import Text       "mo:core/Text";
import Array      "mo:core/Array";
import Iter       "mo:core/Iter";
import Principal  "mo:core/Principal";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _NatValue "../src/NatValue";
import _PrincipalValue "../src/PrincipalValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Predicate  "../src/Predicate";
import Registry   "../src/Registry";

type Customer = { id : Nat; country : Text; owner : Principal };
type Order    = { id : Nat; customerId : Nat; amount : Nat };

let pA = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let pB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;
// Deny / scope only the JOIN TARGET; the start stays unrestricted so the
// planner may fire.
let denyCustomer : Executor.Access =
  func (d : OQL.Decl) : OQL.Access = if (d.name == "customer") #deny else #unrestricted;
func scopeCustomer(p : Principal) : Executor.Access =
  func (d : OQL.Decl) : OQL.Access = if (d.name == "customer") #scoped p else #unrestricted;

// pA owns customers 1 (DE) and 2 (UK); pB owns 3 (DE) and 4 (FR).
// There is deliberately NO customer 99 — order 16's FK dangles.
let custs : [Customer] = [
  { id = 1; country = "DE"; owner = pA },
  { id = 2; country = "UK"; owner = pA },
  { id = 3; country = "DE"; owner = pB },
  { id = 4; country = "FR"; owner = pB },
];

// `customerId` indexed — the FK the semi-join drives; `amount` deliberately
// not indexed, so own-column filters on it always scan.
let orders = IndexedMap.new<Nat, Order>([ ("customerId", #hash) ]);
orders.put(10, { id = 10; customerId = 1;  amount = 100 });   // DE, pA
orders.put(11, { id = 11; customerId = 2;  amount = 200 });   // UK, pA
orders.put(12, { id = 12; customerId = 1;  amount = 300 });   // DE, pA
orders.put(13, { id = 13; customerId = 3;  amount = 400 });   // DE, pB
orders.put(14, { id = 14; customerId = 4;  amount = 500 });   // FR, pB
orders.put(15, { id = 15; customerId = 2;  amount = 600 });   // UK, pA
orders.put(16, { id = 16; customerId = 99; amount = 700 });   // DANGLING

// One customer decl shared by every registry: owner-scoped, so the same
// fixture serves the unrestricted, denied, and scoped cases.
let customerE = Entity.new<Customer>("customer", func () = custs.values(), "Customer", "id")
  .ownedBy("owner")
  .scopedPerUser()
  .build();

let idxReg  = Registry.build([ customerE,
  orders.entity("order", "Order", "id").edge("customerId", "customer").build() ]);
let scanReg = Registry.build([ customerE,
  Entity.new<Order>("order", func () = orders.values(), "Order", "id").edge("customerId", "customer").build() ]);

// Routing probe: same served index, but the SCAN SOURCE IS EMPTY. Any row it
// returns was produced by the semi-join. The `.sample` (never yielded by the
// source) seeds schema derivation so the `customerId` edge still validates.
let probeB = orders.entity("order", "Order", "id")
  .edge("customerId", "customer")
  .sample({ id = 0; customerId = 0; amount = 0 });
let probeE = Entity.build({ probeB with
  source = func (_ : ?Principal) : Iter.Iter<Order> = Iter.empty<Order>() });
let probeReg = Registry.build([ customerE, probeE ]);

// ── helpers ────────────────────────────────────────────────────────────────

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

func run(reg : Registry.Registry, qq : Query.Query, access : Executor.Access) : [[Executor.Cell]] =
  Executor.runWith(reg, qq, access).rows;

func ids(rows : [[Executor.Cell]]) : [Nat] {
  let ns = Array.map<[Executor.Cell], Nat>(rows, func r =
    switch (cell(r, "id")) { case (?(#nat n)) { n }; case _ { 0 } });
  Array.sort(ns, Nat.compare)
};

func q(where_ : ?Predicate.Predicate) : Query.Query = {
  start = "order"; where_; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select = null;
};

func aggQ(where_ : ?Predicate.Predicate, groupBy : [OQL.Path], aggregate : [Query.Agg]) : Query.Query = {
  start = "order"; where_; groupBy; aggregate;
  orderBy = []; offset = null; limit = null; select = null;
};

func valueKey(v : OQL.Value) : Text = switch v {
  case (#null_)   { "0" };
  case (#bool b)  { "1" # Bool.toText(b) };
  case (#nat n)   { "2" # Nat.toText(n) };
  case (#int i)   { "3" # Int.toText(i) };
  case (#float f) { "4" # Float.toText(f) };
  case (#text t)  { "5" # t };
};

func rowKey(row : [Executor.Cell]) : Text {
  let parts = Array.map<Executor.Cell, Text>(row, func c = c.name # "=" # valueKey(c.value));
  var s = "";
  for (p in Array.sort(parts, Text.compare).values()) { s := s # p # "|" };
  s
};

// Row multiset as a sorted key list — group/row order may legitimately differ
// between the index stream and the scan, so compare order-independently.
func sortedRowKeys(rows : [[Executor.Cell]]) : [Text] =
  Array.sort(Array.map<[Executor.Cell], Text>(rows, rowKey), Text.compare);

// Differential: index-served == scan == hand-computed expectation.
func check(where_ : ?Predicate.Predicate, access : Executor.Access, expected : [Nat]) {
  let idx  = ids(run(idxReg, q(where_), access));
  let scan = ids(run(scanReg, q(where_), access));
  assert idx == scan;
  assert idx == expected;
};

// As `check` (unrestricted), plus the empty-scan-source probe must agree —
// positive proof this shape rode the semi-join, not the scan.
func checkProved(where_ : ?Predicate.Predicate, expected : [Nat]) {
  check(where_, unrestricted, expected);
  assert ids(run(probeReg, q(where_), unrestricted)) == expected;
};

// ── routing control ────────────────────────────────────────────────────────

test("probe control: the probe entity's scan source really is empty", func () {
  // No edge filter ⇒ no plan ⇒ scan ⇒ nothing. Every non-empty probe result
  // below therefore came through the served semi-join.
  assert ids(run(probeReg, q(null), unrestricted)) == [];
});

// ── dangling FK ────────────────────────────────────────────────────────────

test("edge-#eq never admits the dangling row (proven semi-join)", func () {
  checkProved(?(#eq(["customerId", "country"], #text("DE"))), [10, 12, 13]);
});

test("edge-#in_ never admits the dangling row (proven semi-join)", func () {
  checkProved(?(#in_(["customerId", "country"], [#text("DE"), #text("FR")])), [10, 12, 13, 14]);
});

test("edge-range #ge never admits the dangling row (proven semi-join)", func () {
  // every real customer's country >= "DE" — only the dangling order is out.
  checkProved(?(#ge(["customerId", "country"], #text("DE"))), [10, 11, 12, 13, 14, 15]);
});

test("edge-range #lt (strict) never admits the dangling row (proven semi-join)", func () {
  // countries < "UK": DE, DE, FR → customers 1, 3, 4.
  checkProved(?(#lt(["customerId", "country"], #text("UK"))), [10, 12, 13, 14]);
});

test("no edge filter: the dangling row still appears", func () {
  check(null, unrestricted, [10, 11, 12, 13, 14, 15, 16]);
});

test("own-column filter: the dangling row still appears", func () {
  check(?(#ge(["amount"], #nat(400))), unrestricted, [13, 14, 15, 16]);
});

test("edge-#ne admits the dangling row (null policy) — not semi-join shaped", func () {
  // Left-join null passes #ne, so #ne is NOT a valid semi-join drive: a
  // future planner change that serves it naively (FK ∈ matching-target pks)
  // would drop order 16 and fail this differential loudly.
  check(?(#ne(["customerId", "country"], #text("DE"))), unrestricted, [11, 14, 15, 16]);
});

test("select across the edge: the dangling row projects null, identically", func () {
  let sel : ?[[Text]] = ?[["id"], ["customerId", "country"]];
  for (reg in [idxReg, scanReg].values()) {
    let rows = run(reg, { q(null) with select = sel }, unrestricted);
    assert rows.size() == 7;
    for (row in rows.values()) {
      let c = cell(row, "customerId.country");
      switch (cell(row, "id")) {
        case (?(#nat 16))              { assert c == ?(#null_) };       // dangling → left-join null
        case (?(#nat 11) or ?(#nat 15)) { assert c == ?(#text("UK")) };
        case (?(#nat 14))              { assert c == ?(#text("FR")) };
        case _                         { assert c == ?(#text("DE")) };
      };
    };
  };
});

// ── denied join target ─────────────────────────────────────────────────────

test("denied target: every edge-filter shape admits nothing, matching the scan", func () {
  check(?(#eq(["customerId", "country"], #text("DE"))), denyCustomer, []);
  check(?(#in_(["customerId", "country"], [#text("DE"), #text("FR")])), denyCustomer, []);
  check(?(#ge(["customerId", "country"], #text("DE"))), denyCustomer, []);
});

test("denied target: rows stay visible without the edge filter, traversal is null", func () {
  let sel : ?[[Text]] = ?[["id"], ["customerId", "country"]];
  for (reg in [idxReg, scanReg].values()) {
    let rows = run(reg, { q(null) with select = sel }, denyCustomer);
    assert rows.size() == 7;   // all orders visible — only the traversal is nulled
    for (row in rows.values()) { assert cell(row, "customerId.country") == ?(#null_) };
  };
});

// ── scoped join target ─────────────────────────────────────────────────────

test("scoped target: only the subject's rows drive the semi-join — no leak", func () {
  // Under pA, customer 3 (DE, owned by pB) is invisible: order 13 must NOT
  // surface through a DE filter, in the semi-join exactly as in the scan.
  check(?(#eq(["customerId", "country"], #text("DE"))), scopeCustomer(pA), [10, 12]);
  check(?(#in_(["customerId", "country"], [#text("DE"), #text("FR")])), scopeCustomer(pA), [10, 12]);
  check(?(#eq(["customerId", "country"], #text("DE"))), scopeCustomer(pB), [13]);
});

test("scoped target: traversal into another owner's row is null, identically", func () {
  let sel : ?[[Text]] = ?[["id"], ["customerId", "country"]];
  for (reg in [idxReg, scanReg].values()) {
    let rows = run(reg, { q(null) with select = sel }, scopeCustomer(pA));
    assert rows.size() == 7;
    for (row in rows.values()) {
      let c = cell(row, "customerId.country");
      switch (cell(row, "id")) {
        case (?(#nat 10) or ?(#nat 12)) { assert c == ?(#text("DE")) };  // pA's customer 1
        case (?(#nat 11) or ?(#nat 15)) { assert c == ?(#text("UK")) };  // pA's customer 2
        case _                          { assert c == ?(#null_) };       // pB's customers + dangling
      };
    };
  };
});

// ── aggregation over the semi-join ─────────────────────────────────────────

test("groupBy + aggregates over a semi-join-served query equal the scan's", func () {
  let qq = aggQ(
    ?(#eq(["customerId", "country"], #text("DE"))),
    [["customerId"]],
    [ { fn = #count; field = null; as_ = null },
      { fn = #sum; field = ?["amount"]; as_ = null } ]);
  let idx   = run(idxReg,   qq, unrestricted);
  let scan  = run(scanReg,  qq, unrestricted);
  let probe = run(probeReg, qq, unrestricted);
  // Group order is first-seen and may differ between streams — compare as
  // multisets; the probe equality proves aggregation consumed semi-join rows.
  assert sortedRowKeys(idx)   == sortedRowKeys(scan);
  assert sortedRowKeys(probe) == sortedRowKeys(scan);
  assert idx.size() == 2;
  for (row in idx.values()) {
    switch (cell(row, "customerId")) {
      case (?(#nat 1)) { assert cell(row, "count") == ?(#nat(2)); assert cell(row, "sum_amount") == ?(#nat(400)) };
      case (?(#nat 3)) { assert cell(row, "count") == ?(#nat(1)); assert cell(row, "sum_amount") == ?(#nat(400)) };
      case _           { assert false };  // no dangling group, no other keys
    };
  };
});

test("ungrouped aggregate over an edge-range semi-join equals the scan's", func () {
  let qq = aggQ(?(#ge(["customerId", "country"], #text("DE"))), [],
    [ { fn = #count; field = null; as_ = null },
      { fn = #sum; field = ?["amount"]; as_ = null } ]);
  for (reg in [idxReg, scanReg, probeReg].values()) {
    let rows = run(reg, qq, unrestricted);
    assert rows.size() == 1;
    assert cell(rows[0], "count") == ?(#nat(6));            // dangling order 16 excluded
    assert cell(rows[0], "sum_amount") == ?(#nat(2100));
  };
});

// ── #in_ duplicates / mixed encodings through the semi-join ────────────────

test("edge-#in_ with duplicate + mixed-encoding keys does not double-count", func () {
  // [#nat 1, #int 1, #nat 1, #nat 3] admits customers 1 and 3 ONCE each; the
  // FK drive must yield each of their orders exactly once.
  let w = ?(#in_(["customerId", "id"], [#nat(1), #int(1), #nat(1), #nat(3)]));
  checkProved(w, [10, 12, 13]);
  // …and a count over the same drive would expose any duplicated posting.
  let qq = aggQ(w, [], [ { fn = #count; field = null; as_ = null } ]);
  for (reg in [idxReg, scanReg, probeReg].values()) {
    let rows = run(reg, qq, unrestricted);
    assert rows.size() == 1;
    assert cell(rows[0], "count") == ?(#nat(3));
  };
});
