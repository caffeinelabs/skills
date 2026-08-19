/// Replica test for columnar `Table`s served through the `Expose` mixin. Runs
/// under PocketIC via `mops test --mode replica --replica pocket-ic`.
///
/// The fixture's tables are empty while the mixin builds its registry, which is
/// how a canister starts life. Deriving an entity's schema from a stored row
/// leaves it with no fields in that state, so `schema()` reports an entity with
/// nothing in it and an edge traversal fails to resolve — both asserted here
/// directly, plus a query that has to cross the edge to answer.

import {test} "mo:test/async";
import Text   "mo:core/Text";
import TableExposed "./fixtures/TableExposed";

actor {

  func contains(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));

  public func runTests() : async () {

    let t = await (with cycles = 10_000_000_000_000) TableExposed.TableExposed();

    // ── schema(), while the tables are still empty ──

    await test("schema() surfaces a Table entity's columns before any row exists", func() : async () {
      let json = await t.schema();
      assert contains(json, "\"name\":\"customer\"");
      assert contains(json, "\"typeName\":\"Customer\"");
      // The declared columns, and the primary key the store position is served as.
      assert contains(json, "\"name\":\"region\"");
      assert contains(json, "\"name\":\"name\"");
      assert contains(json, "\"primaryKey\":\"id\"");
    });

    await test("schema() keeps a Table entity's edge before any row exists", func() : async () {
      let json = await t.schema();
      assert contains(json, "\"name\":\"customerId\"");
      assert contains(json, "\"to\":\"customer\"");
    });

    await test("a Table column's declared type reaches the schema", func() : async () {
      let json = await t.schema();
      assert contains(json, "\"typeName\":\"Nat\"");    // region, customerId, amount
      assert contains(json, "\"typeName\":\"Text\"");   // name
    });

    // ── execute(), once rows exist ──

    await t.seed();

    await test("execute() counts rows of a Table entity", func() : async () {
      let r = await t.execute("{\"start\":\"order\",\"aggregate\":[{\"fn\":\"count\"}]}");
      assert r.rows.size() == 1;
      assert r.rows[0][0].value == #nat(6);
    });

    await test("execute() filters a Table entity on an indexed column", func() : async () {
      let r = await t.execute(
        "{\"start\":\"order\",\"where\":{\"eq\":{\"field\":\"customerId\",\"value\":1}}}");
      assert r.rows.size() == 2;
    });

    await test("execute() traverses a Table entity's edge with a dotted path", func() : async () {
      // Customers 0 and 2 are in region 0, two orders each.
      let r = await t.execute(
        "{\"start\":\"order\",\"where\":{\"eq\":{\"field\":\"customerId.region\",\"value\":0}}}");
      assert r.rows.size() == 4;
    });

    await test("execute() aggregates across a Table entity's edge", func() : async () {
      // Orders of region-0 customers: 10, 20 (cust 0) and 12, 22 (cust 2).
      let r = await t.execute(
        "{\"start\":\"order\",\"where\":{\"eq\":{\"field\":\"customerId.region\",\"value\":0}},"
        # "\"aggregate\":[{\"fn\":\"sum\",\"field\":\"amount\"}]}");
      assert r.rows.size() == 1;
      assert r.rows[0][0].value == #nat(64);
    });

  };

};
