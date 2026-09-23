/// `.hidden` is a data-visibility control, so it must hold on EVERY row source —
/// including a backend's index-served paths, which may build rows straight from
/// storage instead of through the entity's `toPredRow` (the columnar `Table`'s
/// lazy row does exactly that, reading only the columns a query touches).
///
/// Under strict field validation a hidden column is INDISTINGUISHABLE from a
/// nonexistent one — any query referencing it
/// (select, where point/range probe, aggregate) rejects up front as an unknown
/// field, before either backend's row source runs, and the error names only
/// the VISIBLE fields. That closes every disclosure vector this file used to
/// probe row-by-row: the row set, the projection, and index/footer-served
/// aggregates can no longer leak what the validator refuses to reference.
/// Both backends must agree on the reject, and visible columns must keep
/// serving normally. Runs under PocketIC (the Table uses a Region).
import { test } "mo:test/async";
import Error     "mo:core/Error";
import Nat       "mo:core/Nat";
import Text      "mo:core/Text";
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
  func contains(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  type Rec = { id : Nat; grp : Nat; secret : Nat };
  // Two rows sharing grp = 7, with distinct secrets.
  func recs() : [Rec] = [{ id = 0; grp = 7; secret = 111 }, { id = 1; grp = 7; secret = 222 }];
  func recRow(r : Rec) : OQL.Entity.Row = [("id", #nat(r.id)), ("grp", #nat(r.grp)), ("secret", #nat(r.secret))];
  func recCols(r : Rec) : [(Text, OQL.Value)] = [("grp", #nat(r.grp)), ("secret", #nat(r.secret))];

  // Both backends index `grp` AND `secret` — indexing the hidden column is what
  // would let the planner try to serve a probe of it, and lets stats answer
  // over it, if validation ever let such a query through.
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

  // Every disclosure vector, as one probe surface. Called via self-await so
  // the validator's trap arrives as a catchable reject.
  public func probeHidden(backend : Text, vector : Text) : async Nat {
    let reg = if (backend == "heap") heapReg() else tableReg();
    let qq = switch vector {
      // explicit select of the hidden column
      case "select" q(?(#eq(["grp"], #nat(7))), [], ?[["id"], ["secret"]]);
      // point probe — the row COUNT would reveal which row holds 111
      case "where"  q(?(#and_([#eq(["grp"], #nat(7)), #eq(["secret"], #nat(111))])), [], ?[["id"]]);
      // range probe through the #ordered index
      case "range"  q(?(#ge(["secret"], #nat(200))), [], ?[["id"]]);
      // aggregates the Table could serve from footers / the heap from the index
      case "sum"    q(null, [{ fn = #sum; field = ?["secret"]; as_ = null }], null);
      case "min"    q(null, [{ fn = #min; field = ?["secret"]; as_ = null }], null);
      case _        q(null, [{ fn = #max; field = ?["secret"]; as_ = null }], null);
    };
    run(reg, qq).size();
  };

  public func runTests() : async () {
    await test("every reference to a hidden column rejects as unknown, on both backends", func() : async () {
      for (backend in (["heap", "table"] : [Text]).values()) {
        for (vector in (["select", "where", "range", "sum", "min", "max"] : [Text]).values()) {
          var rejected = false;
          try {
            ignore await probeHidden(backend, vector);
          } catch (e) {
            rejected := true;
            let msg = Error.message(e);
            // Rejects exactly like a nonexistent field...
            assert contains(msg, "unknown field 'secret'");
            // ...and the visible-field list does NOT disclose the hidden
            // column: with the quoted probe name removed, no bare `secret`
            // remains anywhere in the message.
            assert contains(msg, "fields:");
            assert not contains(Text.replace(msg, #text("'secret'"), ""), "secret");
            // Never a value leak.
            assert not contains(msg, "111");
            assert not contains(msg, "222");
          };
          assert rejected;
        };
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
