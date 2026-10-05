/// Float group-by keys are exact. A scan used to key a Float group on
/// `f.toText()`, which compiled code formats with six decimals: `0.1000001`
/// and `0.1000002` shared a group, `1e-7` and `1e-18` grouped with `0.0`, and
/// `-0.0` split from `+0.0`. Pinned against hand-counted groups and against
/// the index-served group-count, which keys on the exact value with `-0.0`
/// equal to zero. Runs under PocketIC: the interpreter formats floats at full
/// precision, so only compiled code shows the rounding.
import { test } "mo:test/async";
import Array      "mo:core/Array";
import Map        "mo:core/Map";
import Nat        "mo:core/Nat";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Registry   "../src/Registry";

actor {

  type F = { id : Nat; v : Float };

  // Distinct values, except the two zeros. `0.001` and its neighbour
  // `0.0010000000000000002` differ in the 19th decimal.
  let VS : [Float] = [0.1000001, 0.1000002, 1e-7, 0.0, -0.0, 0.001, 0.0010000000000000002, 1e-18];

  func fRow(f : F) : OQL.Entity.Row = [("id", #nat(f.id)), ("v", #float(f.v))];

  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  let groupV : Query.Query = {
    start = "f"; where_ = null; groupBy = [["v"]];
    aggregate = [{ fn = #count; field = null; as_ = null }];
    orderBy = []; offset = null; limit = null; select = null;
  };

  // A plain `Map` entity (scan) and an `IndexedMap` with `v` indexed, whose
  // group-count is served off the index.
  func regs() : (Registry.Registry, Registry.Registry) {
    let plain = Map.empty<Nat, F>();
    let em    = IndexedMap.new<Nat, F>([("v", #ordered)]);
    for (i in VS.keys()) {
      let f = { id = i; v = VS[i] };
      plain.add(Nat.compare, i, f);
      em.put(i, f, Nat.compare, fRow);
    };
    ( Registry.build([Entity.new<F>("f", func () = plain.values(), "F", "id", fRow).build()]),
      Registry.build([em.entity("f", "F", "id", Nat.compare, fRow).build()]) );
  };

  func cell(row : [Executor.Cell], name : Text) : OQL.Value {
    for (c in row.values()) { if (c.name == name) return c.value };
    #null_
  };

  // (key, count) per group.
  func groups(r : Registry.Registry) : [(OQL.Value, OQL.Value)] =
    Executor.runWith(r, groupV, unrestricted).rows.map<[Executor.Cell], (OQL.Value, OQL.Value)>(
      func row = (cell(row, "v"), cell(row, "count")));

  func countOf(gs : [(OQL.Value, OQL.Value)], key : OQL.Value) : ?OQL.Value {
    for ((k, n) in gs.values()) { if (k == key) return ?n };
    null
  };

  public func runTests() : async () {
    await test("Float group keys are exact, with -0.0 equal to 0.0", func () : async () {
      let (scan, _) = regs();
      let g = groups(scan);
      assert g.size() == 7;
      for (v in VS.values()) {
        assert countOf(g, #float v) == ?(#nat(if (v == 0.0) 2 else 1));
      };
    });

    await test("scan group-count equals the index-served group-count", func () : async () {
      let (scan, idx) = regs();
      let s = groups(scan);
      let i = groups(idx);
      assert s.size() == i.size();
      for ((k, n) in s.values()) { assert countOf(i, k) == ?n };
    });
  };

};
