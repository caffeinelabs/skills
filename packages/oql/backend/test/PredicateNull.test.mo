/// A `#null_` value matches no ordered comparison — from every access path.
///
/// `Predicate.compare` ranks kinds (`null < bool < number < text`) so sorting
/// stays total, and `eval` used to apply that order raw: a stored null compared
/// "less than 0", so `WHERE v < 0` matched every null row. Worse, the answer
/// depended on the access path — the columnar zone map's min/max exclude nulls,
/// so a pruned segment dropped its nulls while a scanned one matched them, and
/// the same query could answer differently at different thresholds.
///
/// Pinned here over FOUR paths that must all agree with a hand-computed truth:
/// a heap scan, a heap `#ordered` index (the planner's index-served range — a
/// superset whose residual filter is the fixed `eval`), a columnar scan, and a
/// columnar table behind its zone map (both an in-range threshold, where rows
/// are evaluated, and an out-of-range one, where whole segments are pruned).
/// `eq`/`ne` against a `#null_` operand stay the explicit is-null / is-not-null
/// tests, and `in` matches a null row only through an explicit `#null_` element.
/// Runs under PocketIC because the columnar table uses a Region.
import { test } "mo:test/async";
import Nat        "mo:core/Nat";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Predicate  "../src/Predicate";
import Registry   "../src/Registry";
import Table      "../src/Table";
import Types      "../src/Types";

actor {

  // v: -5, null, 0, 5, null — every relation below has a hand-checked answer.
  let VS : [Types.Value] = [#int(-5), #null_, #int 0, #int 5, #null_];

  // Rows are carried in row shape directly (a Value-typed field has no _toRow
  // instance to auto-derive), with the identity lineariser passed explicitly.
  func asRow(row : [(Text, Types.Value)]) : [(Text, Types.Value)] = row;

  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  func q(where_ : ?Predicate.Predicate) : Query.Query = {
    start = "e"; where_; groupBy = []; aggregate = [];
    orderBy = []; offset = null; limit = null; select = null;
  };

  // The four registries, same five rows each.
  func heapReg(indexed : Bool) : Registry.Registry {
    let m = IndexedMap.new<Nat, [(Text, Types.Value)]>(if indexed [("v", #ordered)] else []);
    var i = 0;
    for (v in VS.values()) { IndexedMap.put(m, i, [("id", #nat i), ("v", v)], Nat.compare, asRow); i += 1 };
    Registry.build([IndexedMap.entity(m, "e", "E", "id", Nat.compare, asRow).build()]);
  };
  func colReg() : Registry.Registry {
    let t = Table.new([("v", #int)], []);
    for (v in VS.values()) { ignore Table.append(t, [("v", v)], asRow) };
    Table.flush(t);
    Registry.build([Table.entityWith(t, "e", "E", "id").build()]);
  };

  public func runTests() : async () {
    await test("ordered, eq/ne and in null semantics agree on every path", func() : async () {
      let paths = [heapReg(false), heapReg(true), colReg()];
      let cases : [(Text, Predicate.Predicate, Nat)] = [
        ("v < 0",        #lt(["v"], #int 0), 1),      // just -5 — the bug matched the nulls too
        ("v <= 0",       #le(["v"], #int 0), 2),
        ("v > 0",        #gt(["v"], #int 0), 1),
        ("v >= 0",       #ge(["v"], #int 0), 2),
        ("v >= -5",      #ge(["v"], #int(-5)), 3),
        ("v < -100",     #lt(["v"], #int(-100)), 0),  // zone map prunes columnar; heap must agree
        ("v > 100",      #gt(["v"], #int 100), 0),
        ("v < null",     #lt(["v"], #null_), 0),      // a null operand bounds nothing
        ("v >= null",    #ge(["v"], #null_), 0),
        ("v = null",     #eq(["v"], #null_), 2),      // explicit is-null stays
        ("v != null",    #ne(["v"], #null_), 3),      // explicit is-not-null stays
        ("v in [5]",     #in_(["v"], [#int 5]), 1),
        ("v in [null,5]", #in_(["v"], [#null_, #int 5]), 3),  // null only via an explicit element
        ("not (v < 0)",  #not_(#lt(["v"], #int 0)), 4),        // negation includes the nulls
      ];
      for (reg in paths.values()) {
        for ((name, p, want) in cases.values()) {
          let got = Executor.runWith(reg, q(?p), unrestricted).rows.size();
          if (got != want) {
            assert false;   // name/want identify the case; paths are ordered heap-scan, heap-indexed, columnar
          };
        };
        // The same truths as AGGREGATE counts. Today a filtered count re-runs
        // eval over the scan (the planner refuses to serve a range count from
        // anything precomputed), so this follows from the row cases — but that
        // refusal is the ONLY thing keeping it true, and it is exactly the
        // invariant a future optimization would break: the per-segment zone-map
        // counts exclude nulls at pruned thresholds and include them at
        // in-range ones, so serving `count(*) where v < c` from them would
        // reintroduce the bug with every row-count test above still green.
        for ((name, p, want) in cases.values()) {
          let res = Executor.runWith(reg, {
            start = "e"; where_ = ?p; groupBy = []; orderBy = [];
            aggregate = [{ fn = #count; field = null; as_ = null }];
            offset = null; limit = null; select = null;
          }, unrestricted);
          assert res.rows.size() == 1;
          assert res.rows[0][0].value == #nat(want);
        };
      };
    });

    await test("an absent field differs from a stored null exactly as documented", func() : async () {
      // Three rows that DON'T carry `v` at all. Absent fails everything except
      // `ne` — which is true for ANY operand — so is-null does not see it and
      // is-not-null does. The README's null-semantics section states this
      // asymmetry; this pins it.
      let m = IndexedMap.new<Nat, [(Text, Types.Value)]>([]);
      var i = 0;
      while (i < 3) { IndexedMap.put(m, i, [("id", #nat i)], Nat.compare, asRow); i += 1 };
      let reg = Registry.build([IndexedMap.entity(m, "e", "E", "id", Nat.compare, asRow).build()]);
      let cases : [(Predicate.Predicate, Nat)] = [
        (#lt(["v"], #int 0), 0),
        (#ge(["v"], #int 0), 0),
        (#eq(["v"], #null_), 0),    // a stored null WOULD match; absent does not
        (#ne(["v"], #null_), 3),    // ...and ne is true for any operand
        (#ne(["v"], #int 5), 3),
        (#in_(["v"], [#null_]), 0),
      ];
      for ((p, want) in cases.values()) {
        assert Executor.runWith(reg, q(?p), unrestricted).rows.size() == want;
      };
    });
  };
};
