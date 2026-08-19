/// `.hidden` is a data-visibility control, so it must hold on EVERY row source —
/// including a backend's index-served paths, which may build rows straight from
/// storage instead of through the entity's `toPredRow` (the columnar `Table`'s
/// lazy row does exactly that, reading only the columns a query touches).
///
/// Each case runs the identical query against a heap `IndexedMap` and a columnar
/// `Table` over the same logical rows, with the same column hidden, and asserts
/// they agree AND that the hidden value never surfaces. The heap path is the
/// reference: a hidden column reads as absent, so a projection of it yields
/// `#null_` and a predicate on it matches nothing.
///
/// Attack vectors covered, all reachable with `#unrestricted` access:
///   - explicit `select` of a hidden column (an explicit select is honoured
///     verbatim, so protection has to come from the row itself)
///   - a `where` predicate on a hidden column — the row SET would otherwise
///     disclose which rows hold a probed value, even unprojected
///   - an aggregate over a hidden column (served from the index or, for a
///     Table, the segment footers)
/// Runs under PocketIC (the Table uses a Region).
import { test } "mo:test/async";
import Nat       "mo:core/Nat";
import OQL       "../src";
import Entity    "../src/Entity";
import Executor  "../src/Executor";
import Query     "../src/Query";
import Registry  "../src/Registry";
import IndexedMap "../src/IndexedMap";
import Table     "../src/Table";
import _NatValue "../src/NatValue";
import _RecordValue "../src/RecordValue";

actor {
  func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
    for (c in row.values()) { if (c.name == name) return ?c.value };
    null;
  };
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  type Rec = { id : Nat; grp : Nat; secret : Nat };
  // Two rows sharing grp = 7, with distinct secrets.
  func recs() : [Rec] = [{ id = 0; grp = 7; secret = 111 }, { id = 1; grp = 7; secret = 222 }];
  func recRow(r : Rec) : OQL.Entity.Row = [("id", #nat(r.id)), ("grp", #nat(r.grp)), ("secret", #nat(r.secret))];
  func recCols(r : Rec) : [(Text, OQL.Value)] = [("grp", #nat(r.grp)), ("secret", #nat(r.secret))];

  // Both backends index `grp` AND `secret` — indexing the hidden column is what
  // lets the planner try to serve a probe of it, and lets stats answer over it.
  func heapReg() : Registry.Registry {
    let m = IndexedMap.new<Nat, Rec>([("grp", #hash), ("secret", #ordered)]);
    for (r in recs().values()) { m.put(r.id, r, Nat.compare, recRow) };
    Registry.build([m.entity("rec", "Rec", "id", Nat.compare, recRow).hidden("secret").build()]);
  };
  func tableReg() : Registry.Registry {
    let t = Table.newWith([("grp", #nat), ("secret", #nat)], [("grp", #hash), ("secret", #ordered)], [], 0);
    for (r in recs().values()) { ignore Table.append(t, r, recCols) };
    Table.flush(t);
    Registry.build([Entity.build(Table.entity(t, "rec").hidden("secret"))]);
  };

  func q(where_ : ?OQL.Predicate, aggregate : [Query.Agg], select : ?[[Text]]) : Query.Query = {
    start = "rec"; where_; groupBy = []; aggregate; orderBy = []; offset = null; limit = null; select;
  };
  func run(r : Registry.Registry, qq : Query.Query) : [[Executor.Cell]] =
    Executor.runWith(r, qq, unrestricted).rows;

  public func runTests() : async () {
    await test("hidden column is not readable via an explicit select", func() : async () {
      // #eq on the indexed visible column routes to a served point probe, whose
      // rows the Table builds lazily from the Region.
      let qq = q(?(#eq(["grp"], #nat(7))), [], ?[["id"], ["secret"]]);
      let h = run(heapReg(), qq);
      let c = run(tableReg(), qq);
      assert h.size() == 2 and c.size() == 2;
      assert cell(h[0], "secret") == ?#null_;   // heap reference: absent → #null_
      assert cell(c[0], "secret") == ?#null_;   // Table must not disclose 111
      assert cell(c[0], "secret") != ?#nat(111);
    });

    await test("hidden column is not readable via the pruned/unfiltered scan", func() : async () {
      // No predicate → the Table takes its zone-map `prune` scan fall-back.
      let qq = q(null, [], ?[["id"], ["secret"]]);
      let h = run(heapReg(), qq);
      let c = run(tableReg(), qq);
      assert h.size() == 2 and c.size() == 2;
      assert cell(c[0], "secret") == ?#null_;
      assert cell(c[1], "secret") == ?#null_;
    });

    await test("hidden column is not probeable via a where predicate", func() : async () {
      // The oracle: even unprojected, a differing row COUNT would reveal which
      // row holds 111. On the heap the hidden cell reads null, so #eq matches
      // nothing; the Table must agree.
      let qq = q(?(#and_([#eq(["grp"], #nat(7)), #eq(["secret"], #nat(111))])), [], ?[["id"]]);
      let h = run(heapReg(), qq);
      let c = run(tableReg(), qq);
      assert h.size() == 0;        // reference: unprobeable
      assert c.size() == h.size(); // a match here would be a disclosure
    });

    await test("hidden column is not probeable via a range predicate", func() : async () {
      // Same oracle through the #ordered index (a range plan rather than a point).
      let qq = q(?(#ge(["secret"], #nat(200))), [], ?[["id"]]);
      let h = run(heapReg(), qq);
      let c = run(tableReg(), qq);
      assert h.size() == 0;
      assert c.size() == h.size();
    });

    await test("aggregates over a hidden column do not disclose it", func() : async () {
      // sum/min/max over `secret`: the Table could serve sum from its segment
      // footers and min/max from the index, the heap min/max from the index.
      // All must fall back to the scan, which sees the masked (absent) cell.
      for (a in ([{ fn = #sum; field = ?["secret"]; as_ = null },
                  { fn = #min; field = ?["secret"]; as_ = null },
                  { fn = #max; field = ?["secret"]; as_ = null }] : [Query.Agg]).values()) {
        let qq = q(null, [a], null);
        let h = run(heapReg(), qq);
        let c = run(tableReg(), qq);
        assert h.size() == 1 and c.size() == 1;
        // Whatever the scan yields for an all-absent column, both agree — and
        // neither reports a real secret (111, 222, or their sum 333).
        assert cell(c[0], "sum_secret") != ?#nat(333);
        assert cell(c[0], "min_secret") != ?#nat(111);
        assert cell(c[0], "max_secret") != ?#nat(222);
        assert cell(h[0], "sum_secret") == cell(c[0], "sum_secret");
        assert cell(h[0], "min_secret") == cell(c[0], "min_secret");
        assert cell(h[0], "max_secret") == cell(c[0], "max_secret");
      };
    });

    await test("a visible column still serves normally alongside a hidden one", func() : async () {
      // The masking must not break the columns that ARE visible.
      let qq = q(?(#eq(["grp"], #nat(7))), [], ?[["id"], ["grp"]]);
      let c = run(tableReg(), qq);
      assert c.size() == 2;
      assert cell(c[0], "grp") == ?#nat(7);
      let sumq = q(null, [{ fn = #sum; field = ?["grp"]; as_ = null }], null);
      assert cell(run(tableReg(), sumq)[0], "sum_grp") == ?#nat(14);  // still footer-served
    });
  };
};
