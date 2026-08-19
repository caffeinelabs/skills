/// Ship-readiness: every OQL entity/query feature must behave the same over a
/// columnar `Table` as over the heap path. For each feature we build a heap
/// reference entity and a `Table` entity over identical logical rows, decorate
/// both the same way, run the same (query, access), and assert identical rows:
///   - `.ownedBy` (default owner==caller) row scoping under a scoped subject
///   - `.ownedByWith` (custom visibility predicate)
///   - `.viewWith` (per-subject row projection)
///   - `.hidden` (column dropped from the schema/projection)
///   - a composite index served
///   - an FK `.edge` filter-behind-the-edge (semi-join)
///   - orderBy + offset + limit
/// Runs under PocketIC (the Table uses a Region).
import { test } "mo:test/async";
import Array     "mo:core/Array";
import Text      "mo:core/Text";
import Nat       "mo:core/Nat";
import Principal "mo:core/Principal";
import OQL       "../src";
import Entity    "../src/Entity";
import Executor  "../src/Executor";
import Query     "../src/Query";
import Registry  "../src/Registry";
import IndexedMap "../src/IndexedMap";
import Table     "../src/Table";
import Cell      "../src/columnar/Cell";
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";

actor {
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
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  // Three demo principals.
  let p1 = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
  let p2 = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");
  let p3 = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");
  func owners() : [Principal] = [p1, p2, p3];

  // Logical row k: owner cycles p1/p2/p3, amount = k*10.
  type Rec = { id : Nat; owner : Principal; amount : Nat };
  func mk(k : Nat) : Rec = { id = k; owner = owners()[k % 3]; amount = k * 10 };
  func recRow(r : Rec) : OQL.Entity.Row =
    [("id", #nat(r.id)), ("owner", #text(Principal.toText(r.owner))), ("amount", #nat(r.amount))];
  func recCols(r : Rec) : [(Text, OQL.Value)] =
    [("owner", #text(Principal.toText(r.owner))), ("amount", #nat(r.amount))];

  let N = 30;
  func recs() : [Rec] = Array.tabulate<Rec>(N, mk);

  // A heap IndexedMap entity builder over the rows (id-ordered, so its PK "id"
  // equals the Table's store position).
  func heapBuilder() : Entity.Builder<Rec> {
    let m = IndexedMap.new<Nat, Rec>([("amount", #ordered), ("owner", #hash)]);
    for (r in recs().values()) { m.put(r.id, r, Nat.compare, recRow) };
    m.entity("rec", "Rec", "id", Nat.compare, recRow);
  };
  func tableBuilder() : Entity.Builder<(Nat, [?Cell.Cell])> {
    // (the Builder type param is opaque; we only .build() it)
    let t = Table.newWith([("owner", #text), ("amount", #nat)], [("amount", #ordered), ("owner", #hash)], [], 0);
    for (r in recs().values()) { ignore Table.append(t, r, recCols) };
    Table.flush(t);
    Table.entityWith(t, "rec", "Rec", "id");
  };

  func q(where_ : ?OQL.Predicate, orderBy : [Query.OrderBy], offset : ?Nat, limit : ?Nat, select : ?[[Text]]) : Query.Query = {
    start = "rec"; where_; groupBy = []; aggregate = []; orderBy; offset; limit; select;
  };

  // ── Adversarial semi-join fixtures ─────────────────────────────────────────
  // These pin the dropped-residual optimisation (planJoin rewrites an edge
  // filter into an `#in_` on the FK index and REMOVES that conjunct from the
  // residual). A Table-vs-heap differential cannot catch a bug in that logic —
  // both run the same `Executor.planJoin` — so the ground truth here is an
  // UNSERVED plain-array `order` entity: with no `served` index the executor
  // never plans, scans every row, and re-applies the FULL predicate. If the
  // dropped residual were wrong, the planned paths would diverge from it.
  type Cust2 = { id : Nat; country : Text };
  let custs2 = [{ id = 0; country = "DE" }, { id = 1; country = "UK" }, { id = 2; country = "DE" }];
  func cust2Row(c : Cust2) : OQL.Entity.Row = [("id", #nat(c.id)), ("country", #text(c.country))];
  func customerE2() : OQL.Decl = OQL.Entity.new<Cust2>("customer", func () = custs2.values(), "Customer", "id", cust2Row).build();

  type Ord2 = { id : Nat; customerId : Nat; amount : Nat };
  // 12 orders with valid FKs (customerId = k % 3) plus 2 with a DANGLING FK (99,
  // no such customer) — the case where dropping the residual must still exclude
  // the row (its `customerId.country` is null → matches nothing → 99 ∉ pks).
  let ords2 = Array.tabulate<Ord2>(14, func k = { id = k; customerId = (if (k < 12) k % 3 else 99); amount = k });
  func ord2Row(o : Ord2) : OQL.Entity.Row = [("id", #nat(o.id)), ("customerId", #nat(o.customerId)), ("amount", #nat(o.amount))];
  func ord2Cols(o : Ord2) : [(Text, OQL.Value)] = [("customerId", #nat(o.customerId)), ("amount", #nat(o.amount))];

  // The `order` entity three ways over the identical rows, all edged to customer.
  // (a) unserved plain-array scan → NO planJoin → full residual = GROUND TRUTH.
  func orderScan() : OQL.Decl =
    OQL.Entity.new<Ord2>("order", func () = ords2.values(), "Order", "id", ord2Row).edge("customerId", "customer").build();
  // (b) heap IndexedMap (served) → planned.
  func orderHeap() : OQL.Decl {
    let om = IndexedMap.new<Nat, Ord2>([("customerId", #hash)]);
    for (o in ords2.values()) { om.put(o.id, o, Nat.compare, ord2Row) };
    om.entity("order", "Order", "id", Nat.compare, ord2Row).edge("customerId", "customer").build();
  };
  // (c) columnar Table (served) → planned.
  func orderTable() : OQL.Decl {
    let ot = Table.new([("customerId", #nat), ("amount", #nat)], [("customerId", #hash)]);
    for (o in ords2.values()) { ignore Table.append(ot, o, ord2Cols) };
    Table.flush(ot);
    Entity.build(Table.entityWith(ot, "order", "Order", "id").edge("customerId", "customer"));
  };
  func joinQ(where_ : ?OQL.Predicate) : Query.Query = {
    start = "order"; where_; groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null;
    select = ?[["id"], ["amount"]];
  };

  public func runTests() : async () {
    await test(".ownedBy row scoping is identical on Table and heap", func() : async () {
      for (p in owners().values()) {
        let scoped : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p);
        let rHeap  = Registry.build([heapBuilder().ownedBy("owner").build()]);
        let rTable = Registry.build([Entity.build(tableBuilder().ownedBy("owner"))]);
        let tRows = Executor.runWith(rTable, q(null, [], null, null, null), scoped).rows;
        assert sameRows(Executor.runWith(rHeap, q(null, [], null, null, null), scoped).rows, tRows);
        // The Principal stored in a #text column reads back verbatim: every row
        // the caller sees carries its own principal in the owner column.
        assert tRows.size() > 0;
        for (row in tRows.values()) { assert cell(row, "owner") == ?#text(Principal.toText(p)) };
      };
    });

    await test("scoped .ownedBy aggregates are index-served identically on Table and heap", func() : async () {
      // The owner column is #hash-indexed, so a scoped .ownedBy read now routes
      // through the owner index (count off the stats, min/max/sum by seek+fold)
      // instead of scanning. Each must equal the heap fold over the same rows.
      func aggQ(fn : Query.AggFn, field : ?[Text]) : Query.Query = {
        start = "rec"; where_ = null; groupBy = []; aggregate = [{ fn; field; as_ = null }];
        orderBy = []; offset = null; limit = null; select = null;
      };
      let cases : [(Query.AggFn, ?[Text])] =
        [(#count, null), (#min, ?["amount"]), (#max, ?["amount"]), (#sum, ?["amount"])];
      for (p in owners().values()) {
        let scoped : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p);
        let rHeap  = Registry.build([heapBuilder().ownedBy("owner").build()]);
        let rTable = Registry.build([Entity.build(tableBuilder().ownedBy("owner"))]);
        for ((fn, field) in cases.values()) {
          let qq = aggQ(fn, field);
          assert sameRows(Executor.runWith(rHeap, qq, scoped).rows, Executor.runWith(rTable, qq, scoped).rows);
        };
        // Concrete anchor: owner cycles p1/p2/p3 over 30 rows → 10 rows each.
        let cnt = Executor.runWith(rTable, aggQ(#count, null), scoped).rows;
        assert cnt.size() == 1 and cnt[0][0].value == #nat(10);
      };
    });

    await test("scoped .ownedBy + a start-column predicate is index-served identically", func() : async () {
      // owner residual composes with a real predicate on an indexed column.
      let qq = q(?(#ge(["amount"], #nat(100))), [], null, null, null);
      for (p in owners().values()) {
        let scoped : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p);
        let rHeap  = Registry.build([heapBuilder().ownedBy("owner").build()]);
        let rTable = Registry.build([Entity.build(tableBuilder().ownedBy("owner"))]);
        let tRows = Executor.runWith(rTable, qq, scoped).rows;
        assert sameRows(Executor.runWith(rHeap, qq, scoped).rows, tRows);
        for (row in tRows.values()) { assert cell(row, "owner") == ?#text(Principal.toText(p)) };
      };
    });

    await test("scoped .ownedBy cannot seek to another owner's row (leak probe)", func() : async () {
      // Row k=1 has amount=10, owner=p2. p1 seeks the amount index straight to
      // it; the injected owner residual must drop it. p2 keeps it — proving the
      // probe isn't vacuously empty.
      let seekP2sRow = q(?(#eq(["amount"], #nat(10))), [], null, null, null);
      let rTable = Registry.build([Entity.build(tableBuilder().ownedBy("owner"))]);
      let asP1 : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p1);
      let asP2 : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p2);
      assert Executor.runWith(rTable, seekP2sRow, asP1).rows.size() == 0;
      assert Executor.runWith(rTable, seekP2sRow, asP2).rows.size() == 1;
    });

    await test(".ownedByWith custom visibility is identical on Table and heap", func() : async () {
      // p1 sees everything; others see only their own.
      func canSee(subject : Principal, owner : OQL.Value) : Bool =
        subject == p1 or owner == #text(Principal.toText(subject));
      for (p in owners().values()) {
        let scoped : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p);
        let rHeap  = Registry.build([heapBuilder().ownedByWith("owner", canSee).build()]);
        let rTable = Registry.build([Entity.build(tableBuilder().ownedByWith("owner", canSee))]);
        assert sameRows(
          Executor.runWith(rHeap, q(null, [], null, null, null), scoped).rows,
          Executor.runWith(rTable, q(null, [], null, null, null), scoped).rows,
        );
      };
    });

    await test(".ownedByWith + a start-column predicate is index-served identically", func() : async () {
      // The predicate drives the amount index; the admits guard re-scopes the
      // planned superset. Every returned row must still pass canSee.
      func canSee(subject : Principal, owner : OQL.Value) : Bool =
        subject == p1 or owner == #text(Principal.toText(subject));
      let qq = q(?(#ge(["amount"], #nat(100))), [], null, null, null);
      for (p in owners().values()) {
        let scoped : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p);
        let rHeap  = Registry.build([heapBuilder().ownedByWith("owner", canSee).build()]);
        let rTable = Registry.build([Entity.build(tableBuilder().ownedByWith("owner", canSee))]);
        let tRows = Executor.runWith(rTable, qq, scoped).rows;
        assert sameRows(Executor.runWith(rHeap, qq, scoped).rows, tRows);
        assert tRows.size() > 0;
        for (row in tRows.values()) {
          switch (cell(row, "owner")) { case (?ow) assert canSee(p, ow); case null assert false };
        };
      };
    });

    await test(".ownedByWith cannot seek to another owner's row (admits leak probe)", func() : async () {
      // A strict-equality CLOSURE (not .ownedBy) keeps scopeKey null, so the
      // #67 rewrite cannot mask an admits bug: the plan seeks the amount index
      // straight to p2's row and the guard must drop it for p1.
      func strictEq(subject : Principal, owner : OQL.Value) : Bool =
        owner == #text(Principal.toText(subject));
      let seekP2sRow = q(?(#eq(["amount"], #nat(10))), [], null, null, null);
      let rTable = Registry.build([Entity.build(tableBuilder().ownedByWith("owner", strictEq))]);
      let asP1 : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p1);
      let asP2 : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p2);
      assert Executor.runWith(rTable, seekP2sRow, asP1).rows.size() == 0;
      assert Executor.runWith(rTable, seekP2sRow, asP2).rows.size() == 1;
    });

    await test("scoped .ownedByWith aggregates fold the admitted stream, never footer stats", func() : async () {
      // Owner cycles p1/p2/p3 over 30 rows, amount = k*10: p2 owns k=1,4,…,28.
      // The global footer min is #nat(0) (p1's row 0) — serving it to p2 is the
      // leak this pins: p2's min must be its own #nat(10).
      func strictEq(subject : Principal, owner : OQL.Value) : Bool =
        owner == #text(Principal.toText(subject));
      func aggQ(fn : Query.AggFn, field : ?[Text]) : Query.Query = {
        start = "rec"; where_ = null; groupBy = []; aggregate = [{ fn; field; as_ = ?"a" }];
        orderBy = []; offset = null; limit = null; select = null;
      };
      let rHeap  = Registry.build([heapBuilder().ownedByWith("owner", strictEq).build()]);
      let rTable = Registry.build([Entity.build(tableBuilder().ownedByWith("owner", strictEq))]);
      let asP2 : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p2);
      let cases : [(Query.AggFn, ?[Text], OQL.Value)] = [
        (#count, null, #nat(10)),
        (#min, ?["amount"], #nat(10)),
        (#max, ?["amount"], #nat(280)),
        (#sum, ?["amount"], #nat(1450)),
      ];
      for ((fn, field, want) in cases.values()) {
        let t = Executor.runWith(rTable, aggQ(fn, field), asP2).rows;
        assert sameRows(Executor.runWith(rHeap, aggQ(fn, field), asP2).rows, t);
        assert cell(t[0], "a") == ?want;
      };
    });

    await test("scoped .ownedByWith limit/hasMore count only admitted rows", func() : async () {
      // The cap runs after the admits guard: a page of 4 must hold 4 of the
      // caller's OWN rows (not 4 superset rows minus strangers), and hasMore
      // reflects the admitted remainder.
      func strictEq(subject : Principal, owner : OQL.Value) : Bool =
        owner == #text(Principal.toText(subject));
      let qq = q(?(#ge(["amount"], #nat(0))), [], null, ?4, null);
      let rHeap  = Registry.build([heapBuilder().ownedByWith("owner", strictEq).build()]);
      let rTable = Registry.build([Entity.build(tableBuilder().ownedByWith("owner", strictEq))]);
      let asP2 : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p2);
      let t = Executor.runWith(rTable, qq, asP2);
      let h = Executor.runWith(rHeap, qq, asP2);
      assert t.rows.size() == 4 and h.rows.size() == 4;
      assert t.hasMore and h.hasMore;   // p2 owns 10 rows ≥ 0
      for (row in t.rows.values()) { assert cell(row, "owner") == ?#text(Principal.toText(p2)) };
    });

    await test(".hidden drops a column identically", func() : async () {
      let rHeap  = Registry.build([heapBuilder().hidden("amount").build()]);
      let rTable = Registry.build([Entity.build(tableBuilder().hidden("amount"))]);
      let h = Executor.runWith(rHeap, q(null, [], null, null, null), unrestricted).rows;
      let t = Executor.runWith(rTable, q(null, [], null, null, null), unrestricted).rows;
      assert sameRows(h, t);
      assert cell(t[0], "amount") == null;   // hidden → not projected
    });

    await test("composite index served identically on Table and heap", func() : async () {
      // composite (owner, amount): equality prefix on owner + range on amount.
      let m = IndexedMap.newWith<Nat, Rec>([], [(["owner", "amount"], #ordered)]);
      for (r in recs().values()) { m.put(r.id, r, Nat.compare, recRow) };
      let rHeap = Registry.build([m.entity("rec", "Rec", "id", Nat.compare, recRow).build()]);
      let t = Table.newWith([("owner", #text), ("amount", #nat)], [], [(["owner", "amount"], #ordered)], 0);
      for (r in recs().values()) { ignore Table.append(t, r, recCols) };
      Table.flush(t);
      let rTable = Registry.build([Entity.build(Table.entityWith(t, "rec", "Rec", "id"))]);
      let qq = q(?(#and_([#eq(["owner"], #text(Principal.toText(p2))), #ge(["amount"], #nat(100))])), [], null, null, null);
      assert sameRows(Executor.runWith(rHeap, qq, unrestricted).rows, Executor.runWith(rTable, qq, unrestricted).rows);
    });

    await test("orderBy + offset + limit identical on Table and heap", func() : async () {
      let rHeap  = Registry.build([heapBuilder().build()]);
      let rTable = Registry.build([Entity.build(tableBuilder())]);
      let qq = q(null, [{ field = ["amount"]; dir = #desc }], ?5, ?7, null);
      assert sameRows(
        Executor.runWith(rHeap, qq, unrestricted).rows,
        Executor.runWith(rTable, qq, unrestricted).rows,
      );
    });

    await test(".viewWith per-subject projection identical on Table and heap", func() : async () {
      let heapView : Entity.RowView<Rec> = func (_ : Principal, r : Rec) : Rec = { r with amount = 0 }; // redact
      let tableView : Entity.RowView<(Nat, [?Cell.Cell])> =
        func (_ : Principal, row : (Nat, [?Cell.Cell])) : (Nat, [?Cell.Cell]) =
          (row.0, [row.1[0], ?(#nat(0) : Cell.Cell)]);                                            // cells: [owner, amount]
      let scoped : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped(p1);
      let rHeap  = Registry.build([heapBuilder().viewWith(heapView).build()]);
      let rTable = Registry.build([Entity.build(tableBuilder().viewWith(tableView))]);
      let t = Executor.runWith(rTable, q(null, [], null, null, null), scoped).rows;
      assert sameRows(Executor.runWith(rHeap, q(null, [], null, null, null), scoped).rows, t);
      assert cell(t[0], "amount") == ?#nat(0);   // the view applied
    });

    await test("a correctly-typed #float column stores, reads, and footer-sums intact", func() : async () {
      // Guards the ColType/value-kind path: a #float column fed #float values
      // must store the actual doubles (not integer bits) and its footer sum must
      // accumulate them — the exact combination a #nat/#float mismatch would
      // silently corrupt. Also confirms the append-time kind guard doesn't
      // false-trap correct usage.
      func fRow ((f, n) : (Float, Nat)) : OQL.Entity.Row = [("x", #float f), ("n", #nat n)];
      let t = Table.newWith([("x", #float), ("n", #nat)], [], [], 0);
      ignore Table.append<(Float, Nat)>(t, (1.5, 10), fRow);
      ignore Table.append<(Float, Nat)>(t, (2.5, 20), fRow);
      Table.flush(t);
      let r = Registry.build([Entity.build(Table.entity(t, "m"))]);
      let sumq : Query.Query = { start = "m"; where_ = null; groupBy = []; aggregate = [{ fn = #sum; field = ?["x"]; as_ = null }]; orderBy = []; offset = null; limit = null; select = null };
      assert cell(Executor.runWith(r, sumq, unrestricted).rows[0], "sum_x") == ?#float(4.0);   // not zeroed
      let allq : Query.Query = { start = "m"; where_ = null; groupBy = []; aggregate = []; orderBy = [{ field = ["x"]; dir = #asc }]; offset = null; limit = null; select = null };
      assert cell(Executor.runWith(r, allq, unrestricted).rows[0], "x") == ?#float(1.5);         // bytes intact
    });

    await test("#float sum after deleting a large value is exact, not the lossy footer sum", func() : async () {
      // A maintained float sum computes 1e16 + 1.0 = 1e16 at flush, then
      // 1e16 - 1e16 = 0.0 on delete; scanning the one live value is exact (1.0).
      func fRow (f : Float) : OQL.Entity.Row = [("x", #float f)];
      let t = Table.newWith([("x", #float)], [], [], 0);
      ignore Table.append<Float>(t, 1.0e16, fRow);    // pos 0
      ignore Table.append<Float>(t, 1.0, fRow);        // pos 1
      Table.flush(t);
      Table.delete(t, 0);                              // drop the large value
      let r = Registry.build([Entity.build(Table.entity(t, "m"))]);
      let sumq : Query.Query = { start = "m"; where_ = null; groupBy = []; aggregate = [{ fn = #sum; field = ?["x"]; as_ = null }]; orderBy = []; offset = null; limit = null; select = null };
      assert cell(Executor.runWith(r, sumq, unrestricted).rows[0], "sum_x") == ?#float(1.0);
    });

    await test("an out-of-range numeric predicate on a stored column returns empty, not a trap", func() : async () {
      // A stored-but-unindexed column takes the prune scan fallback, whose bound
      // extraction must degrade on a value that can't be a 64-bit cell (here a
      // Nat >= 2^64) rather than trapping the query at plan time.
      func nRow (n : Nat) : OQL.Entity.Row = [("n", #nat n)];
      let t = Table.newWith([("n", #nat)], [], [], 0);
      ignore Table.append<Nat>(t, 1, nRow);
      Table.flush(t);
      let r = Registry.build([Entity.build(Table.entity(t, "m"))]);
      let big = 18_446_744_073_709_551_616;   // 2^64 — beyond a #nat cell
      let qq : Query.Query = { start = "m"; where_ = ?(#eq(["n"], #nat(big))); groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select = null };
      assert Executor.runWith(r, qq, unrestricted).rows.size() == 0;   // no match — and no trap
    });

    await test("a divergent #float FK is excluded by a planned semi-join, matching the scan", func() : async () {
      // customerId is Nat in the seed row but order 1 emits #float(0.0) at
      // runtime — wrapRow left-joins that to null. A planned (served-FK) semi-join
      // must exclude it exactly as the unserved scan does, even though the dropped
      // residual no longer re-checks the edge (planJoin replicates the joinable-FK
      // guard). Ground truth = the unserved plain-array scan.
      let os : [{ id : Nat; fk : OQL.Value }] = [{ id = 0; fk = #nat 0 }, { id = 1; fk = #float 0.0 }];
      func oRow_(o : { id : Nat; fk : OQL.Value }) : OQL.Entity.Row = [("id", #nat(o.id)), ("customerId", o.fk)];
      let scanE = OQL.Entity.new<{ id : Nat; fk : OQL.Value }>("order", func () = os.values(), "Order", "id", oRow_).edge("customerId", "customer").build();
      let om = IndexedMap.new<Nat, { id : Nat; fk : OQL.Value }>([("customerId", #hash)]);
      for (o in os.values()) { om.put(o.id, o, Nat.compare, oRow_) };
      let heapE = om.entity("order", "Order", "id", Nat.compare, oRow_).edge("customerId", "customer").build();
      let qDE : Query.Query = { start = "order"; where_ = ?(#eq(["customerId", "country"], #text("DE"))); groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select = ?[["id"]] };
      let scanR = Executor.runWith(Registry.build([customerE2(), scanE]), qDE, unrestricted).rows;
      let heapR = Executor.runWith(Registry.build([customerE2(), heapE]), qDE, unrestricted).rows;
      assert sameRows(scanR, heapR);                                    // planned == unserved ground truth
      assert scanR.size() == 1 and cell(scanR[0], "id") == ?#nat(0);    // only the #nat FK matches; #float excluded
    });

    await test("edge filter-behind-the-edge (semi-join) identical on Table and heap", func() : async () {
      type Cust = { id : Nat; country : Text };
      let custs = [{ id = 0; country = "DE" }, { id = 1; country = "UK" }, { id = 2; country = "DE" }];
      func custRow(c : Cust) : OQL.Entity.Row = [("id", #nat(c.id)), ("country", #text(c.country))];
      let customerE = OQL.Entity.new<Cust>("customer", func () = custs.values(), "Customer", "id", custRow).build();

      type Ord = { id : Nat; customerId : Nat; amount : Nat };
      let ords = Array.tabulate<Ord>(12, func k = { id = k; customerId = k % 3; amount = k });
      func ordRow(o : Ord) : OQL.Entity.Row = [("id", #nat(o.id)), ("customerId", #nat(o.customerId)), ("amount", #nat(o.amount))];
      func ordCols(o : Ord) : [(Text, OQL.Value)] = [("customerId", #nat(o.customerId)), ("amount", #nat(o.amount))];

      let om = IndexedMap.new<Nat, Ord>([("customerId", #hash)]);
      for (o in ords.values()) { om.put(o.id, o, Nat.compare, ordRow) };
      let rHeap = Registry.build([customerE, om.entity("order", "Order", "id", Nat.compare, ordRow).edge("customerId", "customer").build()]);

      let ot = Table.new([("customerId", #nat), ("amount", #nat)], [("customerId", #hash)]);
      for (o in ords.values()) { ignore Table.append(ot, o, ordCols) };
      Table.flush(ot);
      let rTable = Registry.build([customerE, Entity.build(Table.entityWith(ot, "order", "Order", "id").edge("customerId", "customer"))]);

      let qq : Query.Query = {
        start = "order"; where_ = ?(#eq(["customerId", "country"], #text("DE"))); groupBy = []; aggregate = [];
        orderBy = []; offset = null; limit = null; select = ?[["id"], ["amount"], ["customerId", "country"]];
      };
      assert sameRows(Executor.runWith(rHeap, qq, unrestricted).rows, Executor.runWith(rTable, qq, unrestricted).rows);
    });

    await test("semi-join dropped-residual matches an UNPLANNED scan (valid + dangling FKs)", func() : async () {
      // planJoin serves `customerId.country == "DE"` via `#in_` on the FK index
      // and drops that conjunct from the residual. The unserved scan re-applies
      // it in full, so it independently pins the planned Table and heap paths —
      // including that the 2 dangling-FK orders (99) are excluded, not admitted.
      let where_ = ?(#eq(["customerId", "country"], #text("DE")));
      let scanRows  = Executor.runWith(Registry.build([customerE2(), orderScan()]),  joinQ(where_), unrestricted).rows;
      let heapRows  = Executor.runWith(Registry.build([customerE2(), orderHeap()]),  joinQ(where_), unrestricted).rows;
      let tableRows = Executor.runWith(Registry.build([customerE2(), orderTable()]), joinQ(where_), unrestricted).rows;
      // DE customers are {0, 2}; orders with customerId ∈ {0,2} are k ∈ {0,2,3,5,6,8,9,11}
      // → 8 rows. UK (1) and dangling (99) excluded.
      assert scanRows.size() == 8;
      assert sameRows(tableRows, scanRows);   // columnar planJoin + dropped residual is correct
      assert sameRows(heapRows, scanRows);    // heap planJoin agrees with the ground truth too
    });

    await test("semi-join keeps a start-column residual (amount) — matches an UNPLANNED scan", func() : async () {
      // With a second conjunct on a START column, planJoin drops ONLY the edge
      // conjunct and must retain `amount >= 6` in the residual. If it dropped the
      // wrong conjunct (or all of them), the planned rows would diverge from the
      // scan's.
      let where_ = ?(#and_([#eq(["customerId", "country"], #text("DE")), #ge(["amount"], #nat(6))]));
      let scanRows  = Executor.runWith(Registry.build([customerE2(), orderScan()]),  joinQ(where_), unrestricted).rows;
      let tableRows = Executor.runWith(Registry.build([customerE2(), orderTable()]), joinQ(where_), unrestricted).rows;
      // DE ∧ amount(=k) >= 6 → k ∈ {6, 8, 9, 11} → 4 rows.
      assert scanRows.size() == 4;
      assert sameRows(tableRows, scanRows);
    });

    await test("semi-join into a DENIED target is empty on planned and unplanned paths", func() : async () {
      // A denied dimension admits nothing: planJoin drives the start through
      // `#in_(edge, [])` (empty), and the unserved scan traverses to a null edge
      // whose residual `null == "DE"` is false. Both must yield zero rows — and
      // dropping the residual must not accidentally let denied rows through.
      let denyCustomer : Executor.Access = func (d : OQL.Decl) : OQL.Access = if (d.name == "customer") #deny else #unrestricted;
      let where_ = ?(#eq(["customerId", "country"], #text("DE")));
      let scanRows  = Executor.runWith(Registry.build([customerE2(), orderScan()]),  joinQ(where_), denyCustomer).rows;
      let tableRows = Executor.runWith(Registry.build([customerE2(), orderTable()]), joinQ(where_), denyCustomer).rows;
      assert scanRows.size() == 0;
      assert tableRows.size() == 0;
    });
  };
};
