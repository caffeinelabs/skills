/// Footer-served `sum` for the columnar Table: a whole-column sum must equal a
/// plain scan-fold over the identical live rows, across the split state —
/// flushed segments + an unflushed buffer + tombstones (buffered and flushed) +
/// null cells. The Table declares NO secondary index here, so `sum` is served
/// purely from the segment live-sums (not the index). Runs under PocketIC (the
/// Table uses a Region).
import { test } "mo:test/async";
import Array    "mo:core/Array";
import Text     "mo:core/Text";
import Nat      "mo:core/Nat";
import Table    "../src/Table";
import Entity   "../src/Entity";
import OQL      "../src";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

actor {
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
    for (c in row.values()) { if (c.name == name) return ?c.value };
    null;
  };
  func valueKey(v : OQL.Value) : Text = switch v {
    case (#null_) "0"; case (#bool b) "1" # (if b "T" else "F");
    case (#nat n) "2" # Nat.toText(n); case (#int i) "3" # debug_show (i);
    case (#float f) "4" # debug_show (f); case (#text t) "5" # t;
  };
  func rowKey(row : [Executor.Cell]) : Text {
    var s = "";
    for (c in Array.sort(Array.map<Executor.Cell, Text>(row, func c = c.name # "=" # valueKey(c.value)), Text.compare).values()) { s := s # c # "|" };
    s;
  };
  func sameRows(a : [[Executor.Cell]], b : [[Executor.Cell]]) : Bool {
    if (a.size() != b.size()) return false;
    Array.sort(Array.map<[Executor.Cell], Text>(a, rowKey), Text.compare)
      == Array.sort(Array.map<[Executor.Cell], Text>(b, rowKey), Text.compare);
  };

  // Column values for logical row p: a = p, b = null when p % 3 == 0 else p*2,
  // c = -p. Shared by the Table (append) and the reference (scan).
  func tableRow(p : Nat) : [(Text, OQL.Value)] = [
    ("a", #nat p),
    ("b", if (p % 3 == 0) #null_ else #nat(p * 2)),
    ("c", #int(-p)),
  ];
  type R = { id : Nat; a : Nat; b : ?Nat; c : Int };
  func refRow(r : R) : OQL.Entity.Row = [
    ("id", #nat(r.id)), ("a", #nat(r.a)),
    ("b", switch (r.b) { case (?x) #nat x; case null #null_ }),
    ("c", #int(r.c)),
  ];

  // For the lazy-projection test: two columns, a indexed.
  func ab(x : Nat) : [(Text, OQL.Value)] = [("a", #nat(x % 3)), ("b", #nat(x * 10))];
  type AB = { id : Nat; a : Nat; b : Nat };
  func abRef(r : AB) : OQL.Entity.Row = [("id", #nat(r.id)), ("a", #nat(r.a)), ("b", #nat(r.b))];

  // For the zone-map test: monotonic `amount` → segments get disjoint [min,max].
  func amtCols(x : Nat) : [(Text, OQL.Value)] = [("amount", #nat(x)), ("tag", #nat(x % 2))];
  type Amt = { id : Nat; amount : Nat; tag : Nat };
  func amtRef(r : Amt) : OQL.Entity.Row = [("id", #nat(r.id)), ("amount", #nat(r.amount)), ("tag", #nat(r.tag))];

  // For the var-width text test: a nullable text column + a numeric one.
  func nameRow(k : Nat) : [(Text, OQL.Value)] = [
    ("name", if (k % 4 == 0) #null_ else #text("n" # Nat.toText(k))),
    ("score", #nat(k)),
  ];
  type Nm = { id : Nat; name : ?Text; score : Nat };
  func nmRef(r : Nm) : OQL.Entity.Row = [
    ("id", #nat(r.id)),
    ("name", switch (r.name) { case (?s) #text s; case null #null_ }),
    ("score", #nat(r.score)),
  ];

  func aggQ(fn : Query.AggFn, col : Text) : Query.Query = {
    start = "t"; where_ = null; groupBy = [];
    aggregate = [{ fn; field = ?[col]; as_ = null }];
    orderBy = []; offset = null; limit = null; select = null;
  };
  func sumQ(col : Text) : Query.Query = aggQ(#sum, col);
  func avgQ(col : Text) : Query.Query = aggQ(#avg, col);

  public func runTests() : async () {
    await test("Table footer-served sum == scan-fold across the split state", func() : async () {
      // Manual flush (flushEvery = 0) so the test drives the split; no index.
      let t = Table.newWith([("a", #nat), ("b", #nat), ("c", #int)], [], [], 0);
      var p = 0;
      while (p < 12) { ignore Table.append(t, p, tableRow); p += 1 };
      Table.flush(t); // rows 0..11 in a segment
      while (p < 18) { ignore Table.append(t, p, tableRow); p += 1 };
      Table.delete(t, 3);  // flushed tombstone
      Table.delete(t, 14); // buffered delete
      // no final flush → 12,13,15,16,17 stay buffered (14 deleted)

      // Reference scan entity over the identical live rows (0..17 minus 3, 14).
      let live = Array.filter<Nat>(Array.tabulate<Nat>(18, func i = i), func i = i != 3 and i != 14);
      let refs = Array.map<Nat, R>(live, func p2 = { id = p2; a = p2; b = (if (p2 % 3 == 0) null else ?(p2 * 2)); c = -p2 });
      let rScan = Registry.build([Entity.new<R>("t", func () = refs.values(), "T", "id", refRow).build()]);
      let rTable = Registry.build([Entity.build(Table.entityWith(t, "t", "T", "id"))]);

      for (col in (["a", "b", "c"] : [Text]).values()) {
        assert sameRows(
          Executor.runWith(rTable, sumQ(col), unrestricted).rows,
          Executor.runWith(rScan, sumQ(col), unrestricted).rows,
        );
        assert sameRows(
          Executor.runWith(rTable, avgQ(col), unrestricted).rows,
          Executor.runWith(rScan, avgQ(col), unrestricted).rows,
        );
      };
      // Concrete: Σ a over live = (0+…+17)=153 − 3 − 14 = 136; 16 live rows.
      assert cell(Executor.runWith(rTable, sumQ("a"), unrestricted).rows[0], "sum_a") == ?#nat(136);
      assert cell(Executor.runWith(rTable, sumQ("c"), unrestricted).rows[0], "sum_c") == ?#int(-136);
      assert cell(Executor.runWith(rTable, avgQ("a"), unrestricted).rows[0], "avg_a") == ?#float(136.0 / 16.0);
    });

    await test("Table index-served lazy projection == scan", func() : async () {
      // a is #hash-indexed → `where a == v` is index-served (the lazy row path),
      // projecting only b. Result must equal a plain scan over the same rows.
      let t = Table.new([("a", #nat), ("b", #nat)], [("a", #hash)]);
      var k = 0; while (k < 10) { ignore Table.append(t, k, ab); k += 1 };
      Table.flush(t);
      let refs = Array.tabulate<AB>(10, func x = { id = x; a = x % 3; b = x * 10 });
      let rScan = Registry.build([Entity.new<AB>("t", func () = refs.values(), "T", "id", abRef).build()]);
      let rTable = Registry.build([Entity.build(Table.entityWith(t, "t", "T", "id"))]);
      func selQ(v : Nat) : Query.Query = {
        start = "t"; where_ = ?(#eq(["a"], #nat(v))); groupBy = []; aggregate = [];
        orderBy = []; offset = null; limit = null; select = ?[["b"]];
      };
      for (v in ([0, 1, 2] : [Nat]).values()) {
        assert sameRows(
          Executor.runWith(rTable, selQ(v), unrestricted).rows,
          Executor.runWith(rScan, selQ(v), unrestricted).rows,
        );
      };
    });

    await test("Table zone-map pruned scan == scan", func() : async () {
      // `amount` is NOT indexed → a range on it takes the scan fall-back, which
      // uses the zone-map prune. flushEvery=10 with monotonic amount gives
      // segments with disjoint [min,max], so a narrow range prunes most of them.
      let t = Table.newWith([("amount", #nat), ("tag", #nat)], [], [], 10);
      var k = 0; while (k < 105) { ignore Table.append(t, k, amtCols); k += 1 };
      Table.delete(t, 50);  // flushed
      Table.delete(t, 102); // buffered
      let live = Array.filter<Nat>(Array.tabulate<Nat>(105, func i = i), func i = i != 50 and i != 102);
      let refs = Array.map<Nat, Amt>(live, func i = { id = i; amount = i; tag = i % 2 });
      let rScan = Registry.build([Entity.new<Amt>("t", func () = refs.values(), "T", "id", amtRef).build()]);
      let rTable = Registry.build([Entity.build(Table.entityWith(t, "t", "T", "id"))]);
      func rangeQ(lo : Nat, hi : Nat) : Query.Query = {
        start = "t"; where_ = ?(#and_([#ge(["amount"], #nat(lo)), #le(["amount"], #nat(hi))])); groupBy = [];
        aggregate = []; orderBy = []; offset = null; limit = null; select = null;
      };
      // narrow range (prunes most segments) and a full range (prunes none) must
      // both equal the plain scan.
      assert sameRows(Executor.runWith(rTable, rangeQ(45, 55), unrestricted).rows, Executor.runWith(rScan, rangeQ(45, 55), unrestricted).rows);
      assert sameRows(Executor.runWith(rTable, rangeQ(0, 200), unrestricted).rows, Executor.runWith(rScan, rangeQ(0, 200), unrestricted).rows);
    });

    await test("Table var-width text column across the split state", func() : async () {
      // A nullable #text column, indexed. Exercises the offsets+data layout on
      // flush and the var-width read on scan / index materialization, across
      // segments + unflushed buffer + tombstones + null text cells.
      let t = Table.newWith([("name", #text), ("score", #nat)], [("name", #hash)], [], 0);
      var k = 0; while (k < 8) { ignore Table.append(t, k, nameRow); k += 1 };
      Table.flush(t);                                   // rows 0..7 flushed (0,4 have null name)
      while (k < 12) { ignore Table.append(t, k, nameRow); k += 1 };  // 8..11 buffered (8 null)
      Table.delete(t, 5);  // flushed
      Table.delete(t, 9);  // buffered

      let live = Array.filter<Nat>(Array.tabulate<Nat>(12, func i = i), func i = i != 5 and i != 9);
      let refs = Array.map<Nat, Nm>(live, func i = { id = i; name = (if (i % 4 == 0) null else ?("n" # Nat.toText(i))); score = i });
      let rScan = Registry.build([Entity.new<Nm>("t", func () = refs.values(), "T", "id", nmRef).build()]);
      let rTable = Registry.build([Entity.build(Table.entityWith(t, "t", "T", "id"))]);

      func allQ() : Query.Query = { start = "t"; where_ = null; groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select = null };
      func nameEq(s : Text) : Query.Query = { start = "t"; where_ = ?(#eq(["name"], #text(s))); groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select = null };
      // full scan: every text value (and null) round-trips through the Region
      assert sameRows(Executor.runWith(rTable, allQ(), unrestricted).rows, Executor.runWith(rScan, allQ(), unrestricted).rows);
      // index-served point on the text column: a flushed row and a buffered row
      assert sameRows(Executor.runWith(rTable, nameEq("n6"), unrestricted).rows, Executor.runWith(rScan, nameEq("n6"), unrestricted).rows);
      assert sameRows(Executor.runWith(rTable, nameEq("n11"), unrestricted).rows, Executor.runWith(rScan, nameEq("n11"), unrestricted).rows);
    });
  };
};
