/// `#bytes` columns: fixed-stride raw-byte cells on a columnar `Table`, opaque
/// to the query layer, read through `bytesRuns`. Pins:
///   - append (`appendWithBytes`) + flush → `bytesRuns` reads every vector back,
///     from stored segments and the write buffer alike
///   - null cells and tombstoned rows are skipped by `live`/null
///   - a segment image carrying a #bytes column loads and reads back identically
///   - OQL invisibility: the column is absent from `schema()`, projections and
///     `select`; a predicate naming it matches nothing (no trap)
/// Runs under PocketIC (the Table uses a Region).
import { test } "mo:test/async";
import Array     "mo:core/Array";
import Blob      "mo:core/Blob";
import Nat8      "mo:core/Nat8";
import Region    "mo:core/Region";
import OQL       "../src";
import Entity    "../src/Entity";
import Executor  "../src/Executor";
import Query     "../src/Query";
import Registry  "../src/Registry";
import Table     "../src/Table";
import Cell      "../src/columnar/Cell";
import Columnar  "../src/columnar/Columnar";
import Image     "../src/columnar/Image";

actor {
  let W = 4;   // vector width under test

  func vec(k : Nat) : Blob =
    Blob.fromArray(Array.tabulate<Nat8>(W, func (i : Nat) : Nat8 = Nat8.fromNat((k + i) % 256)));

  // Row k: owner text, amount k*10, vector vec(k) — except k == 3, which has no vector.
  func row(k : Nat) : OQL.Entity.Row = [("owner", #text("p")), ("amount", #nat(k * 10))];
  func mkTable() : Table.Table =
    Table.newWith([("owner", #text), ("vec", #bytes W), ("amount", #nat)], [("amount", #ordered)], [], 0);
  func fill(t : Table.Table, n : Nat) {
    var k = 0;
    while (k < n) {
      if (k == 3) { ignore Table.append<Nat>(t, k, row) }
      else { ignore Table.appendWithBytes<Nat>(t, k, row, [("vec", vec(k))]) };
      k += 1;
    };
  };

  // Read every live vector via bytesRuns as (rowId, bytes) pairs.
  func readAll(t : Table.Table) : [(Nat, Blob)] {
    var out : [(Nat, Blob)] = [];
    for (run in Table.bytesRuns(t, "vec")) {
      switch run {
        case (#stored s) {
          var i = 0;
          while (i < s.rows) {
            if (s.live(i)) {
              let b = Region.loadBlob(s.region, s.base + Nat64.fromNat(i * s.width), s.width);
              out := Array.concat(out, [(s.startRow + i, b)]);
            };
            i += 1;
          };
        };
        case (#buffered r) {
          for (i in r.cells.keys()) {
            switch (r.cells[i]) { case (?b) out := Array.concat(out, [(r.startRow + i, b)]); case null {} };
          };
        };
      };
    };
    out;
  };

  func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
    for (c in row.values()) { if (c.name == name) return ?c.value };
    null;
  };
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;
  func q(where_ : ?OQL.Predicate, select : ?[[Text]]) : Query.Query = {
    start = "r"; where_; groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select;
  };

  public func runTests() : async () {
    await test("append + flush round-trips vectors through bytesRuns, buffer included", func() : async () {
      let t = mkTable();
      fill(t, 6);
      Table.flush(t);
      fill(t, 2);   // rows 6, 7 stay buffered — wait: fill appends k=0,1 again
      let got = readAll(t);
      // 6 flushed rows minus the vector-less row 3, plus 2 buffered (k=0,1 → rows 6,7).
      assert got.size() == 7;
      assert got[0] == (0, vec(0)) and got[2] == (2, vec(2));
      assert got[3] == (4, vec(4));                    // row 3 skipped (null cell)
      assert got[5] == (6, vec(0)) and got[6] == (7, vec(1));   // buffered run
    });

    await test("a tombstoned row is skipped by live()", func() : async () {
      let t = mkTable();
      fill(t, 4);
      Table.flush(t);
      Table.delete(t, 1);
      let got = readAll(t);
      assert got.size() == 2;   // rows 0 and 2 (3 has no vector, 1 is deleted)
      assert got[0].0 == 0 and got[1].0 == 2;
    });

    await test("a row deleted BEFORE the flush is written valid-but-tombstoned", func() : async () {
      // The bufferDead stash flushes the deleted row's bytes into the segment
      // (validity bit set, footer counts it null, tombstone keeps it dead) —
      // the same contract as fixed columns, so an index committed later could
      // reconcile against the value. `bytesRuns` must skip it; `rawRow` (which
      // deliberately ignores tombstones) must still read the bytes back.
      let t = mkTable();
      fill(t, 4);
      Table.delete(t, 1);
      Table.flush(t);
      let got = readAll(t);
      assert got.size() == 2;   // rows 0 and 2 (3 has no vector, 1 deleted pre-flush)
      assert got[0].0 == 0 and got[1].0 == 2;
      assert Columnar.getCell(t.store, 1, 1) == null;   // ordinary reads: dead
      switch (Columnar.rawRow(t.store, 1)) {            // raw read: bytes survive
        case (?cells) assert cells[1] == ?#bytes(vec(1));
        case null assert false;
      };
    });

    await test("a segment image carrying a #bytes column loads and reads back identically", func() : async () {
      let ref = mkTable();
      fill(ref, 5);
      Table.flush(ref);
      let want = readAll(ref);

      let cols : [Cell.ColType] = [#text, #bytes W, #nat];
      let scratch = Region.new();
      let image = Image.build(scratch, cols, 5, func (r : Nat, c : Nat) : ?Cell.Cell =
        switch c {
          case 0 ?#text("p");
          case 1 if (r == 3) null else ?#bytes(vec(r));
          case _ ?#nat(Nat64.fromNat(r * 10));
        });
      let t = Table.newWith([("owner", #text), ("vec", #bytes W), ("amount", #nat)], [], [], 0);
      ignore Table.loadSegment(t, image);
      let got = readAll(t);
      assert got == want;
      // The non-bytes columns arrived intact too.
      assert Columnar.getCell(t.store, 4, 2) == ?#nat(40);
      assert Columnar.getCell(t.store, 3, 1) == null;   // the null vector stayed null
    });

    await test("a #bytes column is invisible to schema, projection and predicates", func() : async () {
      let t = mkTable();
      fill(t, 4);
      Table.flush(t);
      let reg = Registry.build([Entity.build(Table.entityWith(t, "r", "R", "id"))]);

      // schema(): the column is not a field.
      let doc = Registry.schema(reg, unrestricted);
      for (e in doc.entities.values()) {
        for (f in e.fields.values()) { assert f.name != "vec" };
      };

      // Default projection and explicit select never surface it.
      let rows = Executor.runWith(reg, q(null, null), unrestricted).rows;
      assert rows.size() == 4;
      for (r in rows.values()) { assert cell(r, "vec") == null; assert cell(r, "amount") != null };
      // An explicit select renders it as a null cell (as `.hidden` does), never bytes.
      let sel = Executor.runWith(reg, q(null, ?[["vec"], ["amount"]]), unrestricted).rows;
      assert cell(sel[0], "vec") == ?#null_ and cell(sel[0], "amount") == ?#nat(0);

      // A predicate naming it matches nothing — and does not trap.
      assert Executor.runWith(reg, q(?(#eq(["vec"], #text("x"))), null), unrestricted).rows.size() == 0;

      // The rest of the query surface still works over the same table.
      let agg : Query.Query = { start = "r"; where_ = null; groupBy = []; aggregate = [{ fn = #count; field = null; as_ = null }]; orderBy = []; offset = null; limit = null; select = null };
      assert cell(Executor.runWith(reg, agg, unrestricted).rows[0], "count") == ?#nat(4);

      // Aggregates NAMING the bytes column answer exactly as over an all-null
      // column — never served from the footer (whose zero seeds are not answers),
      // never a trap: sum folds to its #nat(0) seed, min/max/avg to #null_.
      func aggQ(fn : Query.AggFn) : Query.Query = {
        start = "r"; where_ = null; groupBy = []; aggregate = [{ fn; field = ?["vec"]; as_ = ?"a" }];
        orderBy = []; offset = null; limit = null; select = null;
      };
      assert cell(Executor.runWith(reg, aggQ(#sum), unrestricted).rows[0], "a") == ?#nat(0);
      assert cell(Executor.runWith(reg, aggQ(#min), unrestricted).rows[0], "a") == ?#null_;
      assert cell(Executor.runWith(reg, aggQ(#max), unrestricted).rows[0], "a") == ?#null_;
      assert cell(Executor.runWith(reg, aggQ(#avg), unrestricted).rows[0], "a") == ?#null_;
    });
  };
};
