/// Regression for competing access paths: a low-selectivity direct equality
/// must not mask a much smaller exact semi-join drive.
import { test } "mo:test";
import Iter       "mo:core/Iter";
import Nat        "mo:core/Nat";
import Principal  "mo:core/Principal";
import Runtime    "mo:core/Runtime";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import Executor   "../src/Executor";
import OQL        "../src";
import Predicate  "../src/Predicate";
import Query      "../src/Query";
import Registry   "../src/Registry";

type Customer = { id : Nat; region : Nat };
type Order = { id : Nat; customerId : Nat; status : Nat; amount : Nat };

func customerRow(c : Customer) : Entity.Row = [
  ("id", #nat(c.id)),
  ("region", #nat(c.region)),
];

func orderRow(o : Order) : Entity.Row = [
  ("id", #nat(o.id)),
  ("customerId", #nat(o.customerId)),
  ("status", #nat(o.status)),
  ("amount", #nat(o.amount)),
];

let customers = IndexedMap.new<Nat, Customer>([("region", #hash)]);
customers.put(1, { id = 1; region = 7 }, Nat.compare, customerRow);
customers.put(2, { id = 2; region = 8 }, Nat.compare, customerRow);
customers.put(3, { id = 3; region = 9 }, Nat.compare, customerRow);

let orders = IndexedMap.new<Nat, Order>([
  ("customerId", #hash),
  ("status", #hash),
]);
orders.put(10, { id = 10; customerId = 1; status = 0; amount = 100 }, Nat.compare, orderRow);
orders.put(11, { id = 11; customerId = 1; status = 1; amount = 200 }, Nat.compare, orderRow);
orders.put(12, { id = 12; customerId = 2; status = 0; amount = 300 }, Nat.compare, orderRow);
orders.put(13, { id = 13; customerId = 2; status = 0; amount = 400 }, Nat.compare, orderRow);
orders.put(14, { id = 14; customerId = 2; status = 0; amount = 500 }, Nat.compare, orderRow);
orders.put(15, { id = 15; customerId = 3; status = 0; amount = 600 }, Nat.compare, orderRow);
orders.put(16, { id = 16; customerId = 3; status = 0; amount = 700 }, Nat.compare, orderRow);
orders.put(17, { id = 17; customerId = 3; status = 1; amount = 800 }, Nat.compare, orderRow);

let customerDecl = customers.entity(
  "customer", "Customer", "id", Nat.compare, customerRow,
).build();
let indexedOrderDecl = orders.entity(
  "order", "Order", "id", Nat.compare, orderRow,
).edge("customerId", "customer").build();
let served : Entity.Served = switch (indexedOrderDecl.served) {
  case (?s) s;
  case null Runtime.trap("expected indexed order entity");
};
let servedStats : Entity.ServedStats = switch (served.stats) {
  case (?s) s;
  case null Runtime.trap("expected indexed order statistics");
};

var statusRowsRead = 0;
var customerRowsRead = 0;
var statusFullCounts = 0;
var statusBoundedCounts = 0;
var customerBoundedCounts = 0;
var syntheticCounts : ?{ status : Nat; customerId : Nat } = null;
var statusCountLimit : ?Nat = null;
var customerCountLimit : ?Nat = null;

func counted(it : Iter.Iter<Predicate.Row>, col : Text) : Iter.Iter<Predicate.Row> = {
  next = func () : ?Predicate.Row =
    switch (it.next()) {
      case (?row) {
        if (col == "status") statusRowsRead += 1 else if (col == "customerId") customerRowsRead += 1;
        ?row
      };
      case null null;
    };
};

// Empty scan source makes every returned row positive proof of index serving.
// Count iterator reads as well, so the tests can distinguish which usable index
// the planner actually chose.
let probedOrderDecl : Entity.Decl = {
  indexedOrderDecl with
  rows = func (_ : ?Principal) : Iter.Iter<Predicate.Row> = Iter.empty();
  served = ?{
    served with
    point = func (col, key) = counted(served.point(col, key), col);
    points = func (col, keys) = counted(served.points(col, keys), col);
    stats = ?{
      servedStats with
      count = func (col, value) {
        if (col == "status") statusFullCounts += 1;
        servedStats.count(col, value)
      };
      countUpTo = func (col, value, limit) {
        if (col == "status") {
          statusBoundedCounts += 1;
          statusCountLimit := ?limit;
        };
        if (col == "customerId") {
          customerBoundedCounts += 1;
          customerCountLimit := ?limit;
        };
        switch syntheticCounts {
          case (?counts) {
            if (col == "status") ?#exact(counts.status)
            else if (col == "customerId") ?#exact(counts.customerId)
            else servedStats.countUpTo(col, value, limit)
          };
          case null servedStats.countUpTo(col, value, limit);
        }
      };
    };
  };
};

let registry = Registry.build([customerDecl, probedOrderDecl]);
let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

func run(q : Query.Query) : [[Executor.Cell]] =
  Executor.runWith(registry, q, unrestricted).rows;

func resetCounters() {
  statusRowsRead := 0;
  customerRowsRead := 0;
  statusFullCounts := 0;
  statusBoundedCounts := 0;
  customerBoundedCounts := 0;
  statusCountLimit := null;
  customerCountLimit := null;
  syntheticCounts := null;
};

func makeQuery(where_ : ?Predicate.Predicate, groupBy : [OQL.Path], aggregate : [Query.Agg]) : Query.Query = {
  start = "order";
  where_;
  groupBy;
  aggregate;
  orderBy = [];
  offset = null;
  limit = null;
  select = null;
};

test("selective semi-join beats low-selectivity direct equality", func () {
  resetCounters();
  let rows = run(makeQuery(
    ?(#and_([
      #eq(["customerId", "region"], #nat(7)),
      #eq(["status"], #nat(0)),
    ])),
    [],
    [
      { fn = #count; field = null; as_ = ?"orders" },
      { fn = #sum; field = ?["amount"]; as_ = ?"total_amount" },
    ],
  ));
  assert rows.size() == 1;
  assert cell(rows[0], "orders") == ?#nat(1);
  assert cell(rows[0], "total_amount") == ?#nat(100);
  assert customerRowsRead == 2;
  assert statusRowsRead == 0;
  assert statusFullCounts == 0;
  assert statusBoundedCounts == 1;
  assert customerBoundedCounts == 1;
});

test("direct status equality remains index-served", func () {
  resetCounters();
  let rows = run(makeQuery(?(#eq(["status"], #nat(1))), [], []));
  assert rows.size() == 2;
  assert statusRowsRead == 2;
  assert customerRowsRead == 0;
  assert statusFullCounts == 0;
  assert statusBoundedCounts == 0;
  assert customerBoundedCounts == 0;
});

test("smaller direct equality beats a costed semi-join", func () {
  resetCounters();
  let rows = run(makeQuery(
    ?(#and_([
      #eq(["customerId", "region"], #nat(9)),
      #eq(["status"], #nat(1)),
    ])),
    [],
    [],
  ));
  assert rows.size() == 1;
  assert cell(rows[0], "id") == ?#nat(17);
  assert statusRowsRead == 2;
  assert customerRowsRead == 0;
  assert statusFullCounts == 0;
  assert statusBoundedCounts == 1;
  // This proves planJoin reached join-side costing; it did not bail before
  // comparing the customerId posting against the two-row direct source.
  assert customerBoundedCounts == 1;
});

test("10,001-candidate join beats 50M-equivalent direct source", func () {
  resetCounters();
  syntheticCounts := ?{ status = 50_000_000; customerId = 10_001 };
  ignore run(makeQuery(
    ?(#and_([
      #eq(["customerId", "region"], #nat(7)),
      #eq(["status"], #nat(0)),
    ])),
    [],
    [],
  ));
  assert customerRowsRead == 2;
  assert statusRowsRead == 0;
  assert statusCountLimit == ?9_999;
  assert customerCountLimit == ?49_999_999;
});

test("10,001-candidate direct source beats 50M-equivalent join", func () {
  resetCounters();
  syntheticCounts := ?{ status = 10_001; customerId = 50_000_000 };
  ignore run(makeQuery(
    ?(#and_([
      #eq(["customerId", "region"], #nat(9)),
      #eq(["status"], #nat(1)),
    ])),
    [],
    [],
  ));
  assert statusRowsRead == 2;
  assert customerRowsRead == 0;
  assert customerCountLimit == ?10_000;
});

test("materially smaller route wins when both counts exceed old cap", func () {
  resetCounters();
  syntheticCounts := ?{ status = 75_000; customerId = 25_000 };
  ignore run(makeQuery(
    ?(#and_([
      #eq(["customerId", "region"], #nat(7)),
      #eq(["status"], #nat(0)),
    ])),
    [],
    [],
  ));
  assert customerRowsRead == 2;
  assert statusRowsRead == 0;
  assert customerCountLimit == ?74_999;
});

test("global status grouping remains stats-served", func () {
  resetCounters();
  let rows = run(makeQuery(
    null,
    [["status"]],
    [{ fn = #count; field = null; as_ = ?"orders" }],
  ));
  assert rows.size() == 2;
  assert statusRowsRead == 0;
  assert customerRowsRead == 0;
});
