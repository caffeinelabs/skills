/// Planner costing over a partially covered Region index must not walk the
/// entire uncovered tail before execution walks the chosen posting.
import { test } "mo:test/async";
import Blob       "mo:core/Blob";
import Iter       "mo:core/Iter";
import Nat        "mo:core/Nat";
import Nat64      "mo:core/Nat64";
import Region     "mo:core/Region";
import Runtime    "mo:core/Runtime";
import Cell       "../src/columnar/Cell";
import HashSegment "../src/columnar/HashSegment";
import Image      "../src/columnar/Image";
import Entity     "../src/Entity";
import Executor   "../src/Executor";
import IndexedMap "../src/IndexedMap";
import OQL        "../src";
import Predicate  "../src/Predicate";
import Query      "../src/Query";
import RegionIndex "../src/RegionIndex";
import Registry   "../src/Registry";
import Table      "../src/Table";

actor {
  let ROWS = 10_020;
  let PREFIX = 20;
  let COLS : [Table.Column] = [
    ("customerId", #nat),
    ("status", #nat),
    ("amount", #nat),
  ];

  type Customer = { id : Nat; region : Nat };

  func customerRow(c : Customer) : Entity.Row = [
    ("id", #nat(c.id)),
    ("region", #nat(c.region)),
  ];

  func customerId(r : Nat) : Nat = if (r < 3) 1 else 2;

  func imageCell(r : Nat, c : Nat) : ?Cell.Cell =
    if (c == 0) ?#nat(Nat64.fromNat(customerId(r)))
    else if (c == 1) ?#nat(0)
    else ?#nat(Nat64.fromNat(r));

  func asRow(row : [(Text, OQL.Value)]) : [(Text, OQL.Value)] = row;

  func commitRange(t : Table.Table, col : Text, columnIndex : Nat, first : Nat, count : Nat) {
    let scratch = Region.new();
    let bytes = HashSegment.build(
      scratch,
      #nat,
      first,
      count,
      func (local : Nat) : ?Cell.Cell = imageCell(first + local, columnIndex),
    );
    ignore Table.putIndexChunk(t, col, #hash, first, bytes.size(), 0, bytes);
    ignore Table.commitIndex(t, col);
  };

  let orders = Table.new(COLS, []);
  let image = Region.new();
  ignore Table.loadSegment(orders, Image.build(image, [#nat, #nat, #nat], ROWS, imageCell));
  commitRange(orders, "customerId", 0, 0, PREFIX);
  commitRange(orders, "status", 1, 0, PREFIX);

  let customers = IndexedMap.new<Nat, Customer>([("region", #hash)]);
  customers.put(1, { id = 1; region = 7 }, Nat.compare, customerRow);
  customers.put(2, { id = 2; region = 8 }, Nat.compare, customerRow);
  transient let customerDecl = customers.entity(
    "customer", "Customer", "id", Nat.compare, customerRow,
  ).build();

  transient let rawOrderDecl = Entity.build(
    Table.entityWith(orders, "order", "Order", "id")
      .edge("customerId", "customer"),
  );
  transient let rawServed = switch (rawOrderDecl.served) {
    case (?s) s;
    case null Runtime.trap("expected served Table entity");
  };
  transient let rawStats = switch (rawServed.stats) {
    case (?s) s;
    case null Runtime.trap("expected Table statistics");
  };

  var statusRowsRead = 0;
  var customerRowsRead = 0;
  var fullCounts = 0;
  var statusCountCalls = 0;
  var customerCountCalls = 0;
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

  transient let orderDecl : Entity.Decl = {
    rawOrderDecl with
    served = ?{
      rawServed with
      point = func (col, value) = counted(rawServed.point(col, value), col);
      points = func (col, values) = counted(rawServed.points(col, values), col);
      stats = ?{
        rawStats with
        count = func (col, value) {
          fullCounts += 1;
          rawStats.count(col, value)
        };
        countUpTo = func (col, value, limit) {
          if (col == "status") {
            statusCountCalls += 1;
            statusCountLimit := ?limit;
          };
          if (col == "customerId") {
            customerCountCalls += 1;
            customerCountLimit := ?limit;
          };
          rawStats.countUpTo(col, value, limit)
        };
      };
    };
  };

  transient let registry = Registry.build([customerDecl, orderDecl]);
  transient let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

  func makeQuery(region : Nat) : Query.Query = {
    start = "order";
    where_ = ?#and_([
      #eq(["customerId", "region"], #nat(region)),
      #eq(["status"], #nat(0)),
    ]);
    groupBy = [];
    aggregate = [{ fn = #count; field = null; as_ = ?"orders" }];
    orderBy = [];
    offset = null;
    limit = null;
    select = null;
  };

  func resultCount(region : Nat) : Nat {
    let rows = Executor.runWith(registry, makeQuery(region), unrestricted).rows;
    assert rows.size() == 1;
    for (cell in rows[0].values()) {
      if (cell.name == "orders") {
        return switch (cell.value) { case (#nat n) n; case _ Runtime.trap("non-Nat count") };
      };
    };
    Runtime.trap("missing count")
  };

  func resetCounters() {
    statusRowsRead := 0;
    customerRowsRead := 0;
    fullCounts := 0;
    statusCountCalls := 0;
    customerCountCalls := 0;
    statusCountLimit := null;
    customerCountLimit := null;
  };

  public func runTests() : async () {
    await test("a below-cap join wins without an unbounded tail count", func () : async () {
      assert RegionIndex.coveredTo(orders.rix, 0) == PREFIX;
      assert RegionIndex.coveredTo(orders.rix, 1) == PREFIX;
      resetCounters();
      assert resultCount(7) == 3;
      assert statusRowsRead == 0;
      assert customerRowsRead == 3;
      assert fullCounts == 0;
      assert statusCountCalls == 1;
      assert customerCountCalls == 1;
      assert statusCountLimit == ?9_999;
      assert customerCountLimit == ?9_999;
    });

    await test("two capped routes preserve direct-equality priority", func () : async () {
      resetCounters();
      assert resultCount(8) == ROWS - 3;
      assert statusRowsRead == ROWS;
      assert customerRowsRead == 0;
      assert fullCounts == 0;
      assert statusCountCalls == 1;
      assert customerCountCalls == 1;
      assert statusCountLimit == ?9_999;
      assert customerCountLimit == ?9_999;
    });

    await test("a fully covered region posting remains exact above the old cap", func () : async () {
      commitRange(orders, "status", 1, PREFIX, ROWS - PREFIX);
      assert rawStats.countUpTo("status", #nat(0), 9_999) == ?#exact(ROWS);
    });
  };
};
