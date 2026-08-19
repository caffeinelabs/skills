/// A semi-join behind an FK edge must return the same rows however the TARGET
/// entity is stored. `planJoin` has a fast path for the case where the edge
/// filter is an `#eq` on a column the target itself indexes (a point probe);
/// every other shape has to fall back to resolving the target's matching rows
/// by other means. This pins that fall-back, because Motoko has no `case`
/// guards — a `case pat if cond {…}` arm matches `pat` and then does nothing
/// when `cond` is false, rather than trying the later arms — so a fast path
/// written that way silently yields NO primary keys, and the semi-join comes
/// back empty.
///
/// Ground truth is an UNSERVED plain-array `order` entity: with no served index
/// the executor never plans a semi-join, scans every row, and applies the full
/// predicate. Every served variant must agree with it.
import { test } "mo:test/async";
import Array     "mo:core/Array";
import Nat       "mo:core/Nat";
import OQL       "../src";
import Entity    "../src/Entity";
import Executor  "../src/Executor";
import Query     "../src/Query";
import Registry  "../src/Registry";
import IndexedMap "../src/IndexedMap";
import Table     "../src/Table";
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";

actor {
  func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
    for (c in row.values()) { if (c.name == name) return ?c.value };
    null;
  };
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  type Cust = { id : Nat; name : Text; country : Text };
  let custs = [
    { id = 0; name = "c0"; country = "DE" },
    { id = 1; name = "c1"; country = "UK" },
    { id = 2; name = "c2"; country = "DE" },
  ];
  func custRow(c : Cust) : OQL.Entity.Row = [("id", #nat(c.id)), ("name", #text(c.name)), ("country", #text(c.country))];
  func custCols(c : Cust) : [(Text, OQL.Value)] = [("name", #text(c.name)), ("country", #text(c.country))];

  type Ord = { id : Nat; customerId : Nat; amount : Nat };
  let ords = Array.tabulate<Ord>(12, func k = { id = k; customerId = k % 3; amount = k });
  func ordRow(o : Ord) : OQL.Entity.Row = [("id", #nat(o.id)), ("customerId", #nat(o.customerId)), ("amount", #nat(o.amount))];
  func ordCols(o : Ord) : [(Text, OQL.Value)] = [("customerId", #nat(o.customerId)), ("amount", #nat(o.amount))];

  // ── customer, three ways ───────────────────────────────────────────────────
  // (a) no served index at all.
  func custPlain() : OQL.Decl =
    OQL.Entity.new<Cust>("customer", func () = custs.values(), "Customer", "id", custRow).build();
  // (b) heap IndexedMap served, but indexed on `name` — NOT on the filtered
  //     `country`. This is the shape that exercises the fall-back.
  func custHeapOtherCol() : OQL.Decl {
    let cm = IndexedMap.new<Nat, Cust>([("name", #hash)]);
    for (c in custs.values()) { cm.put(c.id, c, Nat.compare, custRow) };
    cm.entity("customer", "Customer", "id", Nat.compare, custRow).build();
  };
  // (c) columnar Table served, also indexed on `name` only.
  func custTableOtherCol() : OQL.Decl {
    let ct = Table.newWith([("name", #text), ("country", #text)], [("name", #hash)], [], 0);
    for (c in custs.values()) { ignore Table.append(ct, c, custCols) };
    Table.flush(ct);
    Entity.build(Table.entityWith(ct, "customer", "Customer", "id"));
  };

  // ── order: unserved (ground truth) vs served (plans a semi-join) ───────────
  func ordPlain() : OQL.Decl =
    OQL.Entity.new<Ord>("order", func () = ords.values(), "Order", "id", ordRow).edge("customerId", "customer").build();
  func ordHeap() : OQL.Decl {
    let om = IndexedMap.new<Nat, Ord>([("customerId", #hash)]);
    for (o in ords.values()) { om.put(o.id, o, Nat.compare, ordRow) };
    om.entity("order", "Order", "id", Nat.compare, ordRow).edge("customerId", "customer").build();
  };
  func ordTable() : OQL.Decl {
    let ot = Table.new([("customerId", #nat), ("amount", #nat)], [("customerId", #hash)]);
    for (o in ords.values()) { ignore Table.append(ot, o, ordCols) };
    Table.flush(ot);
    Entity.build(Table.entityWith(ot, "order", "Order", "id").edge("customerId", "customer"));
  };

  // orders of DE customers (ids 0 and 2) → 8 of the 12 rows.
  func qDE() : Query.Query = {
    start = "order"; where_ = ?(#eq(["customerId", "country"], #text("DE")));
    groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select = ?[["id"]];
  };
  func ids(rows : [[Executor.Cell]]) : [Nat] =
    Array.sort(Array.map<[Executor.Cell], Nat>(rows, func r = switch (cell(r, "id")) { case (?#nat n) n; case _ 9_999 }), Nat.compare);

  func run(order : OQL.Decl, customer : OQL.Decl) : [Nat] =
    ids(Executor.runWith(Registry.build([customer, order]), qDE(), unrestricted).rows);

  public func runTests() : async () {
    await test("semi-join agrees with the unserved scan when the target lacks an index on the filtered column", func() : async () {
      // Ground truth: nothing served anywhere → full scan + full predicate.
      let truth = run(ordPlain(), custPlain());
      assert truth == [0, 2, 3, 5, 6, 8, 9, 11];   // customerId 0 or 2

      // Served start + unserved target: planJoin's fall-back path.
      assert run(ordHeap(), custPlain()) == truth;
      assert run(ordTable(), custPlain()) == truth;

      // Served start + SERVED target whose index does not cover `country`.
      assert run(ordHeap(), custHeapOtherCol()) == truth;
      assert run(ordTable(), custHeapOtherCol()) == truth;
      assert run(ordHeap(), custTableOtherCol()) == truth;
      assert run(ordTable(), custTableOtherCol()) == truth;
    });

    await test("semi-join still agrees when the target DOES index the filtered column", func() : async () {
      // The fast path itself: `country` indexed on the target → point probe.
      let cm = IndexedMap.new<Nat, Cust>([("country", #hash)]);
      for (c in custs.values()) { cm.put(c.id, c, Nat.compare, custRow) };
      let custIndexed = cm.entity("customer", "Customer", "id", Nat.compare, custRow).build();
      let truth = run(ordPlain(), custPlain());
      assert run(ordHeap(), custIndexed) == truth;
      assert run(ordTable(), custIndexed) == truth;
    });
  };
};
