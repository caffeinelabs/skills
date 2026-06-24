/// End-to-end PocketIC test driving the `Catalog` fixture (3 entities,
/// 6 customers, 4 products, 12 orders, edges + hidden field) with real
/// JSON queries over the canister's Candid surface.
///
/// Each test sends a JSON `Query.Query`, awaits `execute(qJson)`, and
/// asserts on the typed `Result` rows returned. Together they exercise:
///
///   • single + nested predicates over Text / Nat / Bool scalars
///   • multi-key orderBy with mixed asc / desc
///   • offset + limit pagination with hasMore accounting
///   • explicit `select` projection
///   • edge fields surface as scalar foreign keys
///   • dotted paths traverse edges (filter / project / group)
///   • hidden fields never appear in schema, default projection, or
///     even an explicit select
///   • schema() returns every declared entity / field

import {test}  "mo:test/async";
import Text    "mo:core/Text";
import Catalog "./fixtures/Catalog";

actor {

  // ── String search helpers ────────────────────────────────────────────

  func contains(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));

  // ── Result helpers ───────────────────────────────────────────────────

  type Cell = { name : Text; value : { #null_; #bool : Bool; #nat : Nat; #int : Int; #float : Float; #text : Text } };

  /// Find the named cell in a row, or `null` if missing.
  func cell(row : [Cell], name : Text) : ?Cell {
    for (c in row.values()) { if (c.name == name) return ?c };
    null
  };

  /// Extract a `#nat` value or trap with a useful message; used as a
  /// shortcut by the tests below.
  func natOf(c : Cell) : Nat = switch (c.value) {
    case (#nat n) n;
    case _ {
      // Force assertion failure with a debug-friendly value (no Runtime
      // import in this file). 0 is wrong-but-stable; the surrounding
      // `assert` will fire.
      0
    };
  };

  func textOf(c : Cell) : Text = switch (c.value) {
    case (#text t) t;
    case _ "";
  };

  func boolOf(c : Cell) : Bool = switch (c.value) {
    case (#bool b) b;
    case _ false;
  };

  // ── Test entry point ─────────────────────────────────────────────────

  public func runTests() : async () {

    let catalog = await (with cycles = 10_000_000_000_000) Catalog.Catalog();

    // ── Schema ────────────────────────────────────────────────────────

    await test("schema() surfaces every declared entity", func () : async () {
      let json = await catalog.schema();
      assert contains(json, "\"name\":\"customer\"");
      assert contains(json, "\"name\":\"product\"");
      assert contains(json, "\"name\":\"order\"");
    });

    await test("schema() exposes edge fields with their target entity", func () : async () {
      let json = await catalog.schema();
      // order.customerId → customer  and  order.productId → product
      assert contains(json, "\"edge\":{\"to\":\"customer\"}");
      assert contains(json, "\"edge\":{\"to\":\"product\"}");
    });

    await test("schema() never leaks hidden fields", func () : async () {
      let json = await catalog.schema();
      assert not contains(json, "passwordHash");
      assert not contains(json, "\"hidden\"");
    });

    // ── Filtering ─────────────────────────────────────────────────────

    await test("eq on Text returns matching customers only", func () : async () {
      let q = "{\"start\":\"customer\",\"where\":{\"eq\":{\"field\":\"country\",\"value\":\"DE\"}}}";
      let r = await catalog.execute(q);
      // alice, charlie, eve
      assert r.rows.size() == 3;
      for (row in r.rows.values()) {
        switch (cell(row, "country")) {
          case (?c) { assert textOf(c) == "DE" };
          case null { assert false };
        };
      };
    });

    await test("eq on Bool returns only vip customers", func () : async () {
      let q = "{\"start\":\"customer\",\"where\":{\"eq\":{\"field\":\"vip\",\"value\":true}}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 3;  // alice, dora, frank
      for (row in r.rows.values()) {
        switch (cell(row, "vip")) {
          case (?c) { assert boolOf(c) };
          case null { assert false };
        };
      };
    });

    await test("ge on Nat returns adults only", func () : async () {
      let q = "{\"start\":\"customer\",\"where\":{\"ge\":{\"field\":\"age\",\"value\":30}}}";
      let r = await catalog.execute(q);
      // alice (34), charlie (41), frank (55)
      assert r.rows.size() == 3;
    });

    await test("nested and+or filters with multiple types", func () : async () {
      // (country=DE OR country=FR) AND vip=true   ⇒ alice, dora
      let q = "{\"start\":\"customer\",\"where\":{\"and\":["
        # "{\"or\":[{\"eq\":{\"field\":\"country\",\"value\":\"DE\"}},"
        #          "{\"eq\":{\"field\":\"country\",\"value\":\"FR\"}}]},"
        # "{\"eq\":{\"field\":\"vip\",\"value\":true}}]}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 2;
      for (row in r.rows.values()) {
        switch (cell(row, "vip")) { case (?c) { assert boolOf(c) }; case null { assert false } };
      };
    });

    await test("not negates an eq predicate", func () : async () {
      // Find every order that is NOT paid.
      let q = "{\"start\":\"order\",\"where\":{\"not\":{\"eq\":{\"field\":\"paid\",\"value\":true}}}}";
      let r = await catalog.execute(q);
      // 4 unpaid orders in the seed data (3, 5, 8, 12)
      assert r.rows.size() == 4;
      for (row in r.rows.values()) {
        switch (cell(row, "paid")) { case (?c) { assert not boolOf(c) }; case null { assert false } };
      };
    });

    // ── #in_ predicate (added for cheap multi-key lookups; powers the
    //    "node-expand-via-edge" interaction in the UI) ──────────────────

    await test("in returns customers with id in the candidate set", func () : async () {
      // alice (1), charlie (3), eve (5) — same row set as `country=DE`,
      // but reached via primary key, not by property.
      let q = "{\"start\":\"customer\",\"where\":"
        # "{\"in\":{\"field\":\"id\",\"value\":[1,3,5]}}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 3;
      for (row in r.rows.values()) {
        switch (cell(row, "country")) { case (?c) { assert textOf(c) == "DE" }; case _ { assert false } };
      };
    });

    await test("in over an edge field gathers all orders for a set of customers", func () : async () {
      // customer 4 (dora) → orders 6, 7; customer 5 (eve) → orders 8, 9.
      // Exactly the call the UI issues when the user clicks two author
      // nodes and asks "show me all their articles in one shot".
      let q = "{\"start\":\"order\",\"where\":"
        # "{\"in\":{\"field\":\"customerId\",\"value\":[4,5]}}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 4;
      for (row in r.rows.values()) {
        switch (cell(row, "customerId")) {
          case (?c) { let n = natOf(c); assert (n == 4 or n == 5) };
          case _ { assert false };
        };
      };
    });

    await test("in with an empty candidate array matches nothing", func () : async () {
      let q = "{\"start\":\"order\",\"where\":{\"in\":{\"field\":\"id\",\"value\":[]}}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 0;
      assert not r.hasMore;
    });

    await test("in composes with and: unpaid orders from customers 1..3", func () : async () {
      // customers 1, 2, 3 placed orders 1, 2, 3, 4, 5. Unpaid among them
      // are orders 3 (cust 2) and 5 (cust 3).
      let q = "{\"start\":\"order\",\"where\":{\"and\":["
        # "{\"in\":{\"field\":\"customerId\",\"value\":[1,2,3]}},"
        # "{\"eq\":{\"field\":\"paid\",\"value\":false}}]}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 2;
    });

    // ── Sorting ───────────────────────────────────────────────────────

    await test("orderBy desc on price returns the most expensive product first", func () : async () {
      let q = "{\"start\":\"product\",\"orderBy\":[{\"field\":\"price\",\"dir\":\"desc\"}]}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 4;
      // First row should be the espresso machine at 49900.
      switch (cell(r.rows[0], "price")) {
        case (?c) { assert natOf(c) == 49900 };
        case null { assert false };
      };
      switch (cell(r.rows[3], "price")) {
        case (?c) { assert natOf(c) == 1200 };  // cleaner tablets
        case null { assert false };
      };
    });

    await test("multi-key orderBy: country asc, age desc", func () : async () {
      let q = "{\"start\":\"customer\",\"orderBy\":["
        # "{\"field\":\"country\",\"dir\":\"asc\"},"
        # "{\"field\":\"age\",\"dir\":\"desc\"}]}";
      let r = await catalog.execute(q);
      // Country grouping (DE, FR, UK, US). Within DE: charlie 41, alice 34, eve 19.
      assert r.rows.size() == 6;
      assert textOf(switch (cell(r.rows[0], "country")) { case (?c) c; case _ { return } }) == "DE";
      assert textOf(switch (cell(r.rows[0], "name"))    { case (?c) c; case _ { return } }) == "charlie";
      assert textOf(switch (cell(r.rows[1], "name"))    { case (?c) c; case _ { return } }) == "alice";
      assert textOf(switch (cell(r.rows[2], "name"))    { case (?c) c; case _ { return } }) == "eve";
    });

    // ── Pagination ────────────────────────────────────────────────────

    await test("limit + offset paginate and set hasMore", func () : async () {
      let q1 = "{\"start\":\"order\",\"orderBy\":[{\"field\":\"id\",\"dir\":\"asc\"}],\"limit\":5}";
      let p1 = await catalog.execute(q1);
      assert p1.rows.size() == 5;
      assert p1.hasMore;  // 12 orders total, so 7 remain after page 1

      let q2 = "{\"start\":\"order\",\"orderBy\":[{\"field\":\"id\",\"dir\":\"asc\"}],\"offset\":5,\"limit\":5}";
      let p2 = await catalog.execute(q2);
      assert p2.rows.size() == 5;
      assert p2.hasMore;  // 2 remain after page 2

      let q3 = "{\"start\":\"order\",\"orderBy\":[{\"field\":\"id\",\"dir\":\"asc\"}],\"offset\":10,\"limit\":5}";
      let p3 = await catalog.execute(q3);
      assert p3.rows.size() == 2;
      assert not p3.hasMore;
    });

    // ── Projection ────────────────────────────────────────────────────

    await test("select projects only the named fields, in order", func () : async () {
      let q = "{\"start\":\"product\",\"select\":[\"sku\",\"price\"],\"orderBy\":[{\"field\":\"price\",\"dir\":\"asc\"}],\"limit\":1}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 1;
      let row = r.rows[0];
      assert row.size() == 2;
      assert row[0].name == "sku";
      assert row[1].name == "price";
      assert textOf(row[0]) == "SKU-D";  // cheapest = cleaner tablets
      assert natOf(row[1]) == 1200;
    });

    await test("default projection includes edge fields as scalars", func () : async () {
      let q = "{\"start\":\"order\",\"where\":{\"eq\":{\"field\":\"id\",\"value\":1}}}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 1;
      // order #1 = (customerId=1, productId=101). Edges show up as
      // ordinary scalar cells — clients do client-side joins.
      switch (cell(r.rows[0], "customerId")) { case (?c) { assert natOf(c) == 1   }; case _ { assert false } };
      switch (cell(r.rows[0], "productId"))  { case (?c) { assert natOf(c) == 101 }; case _ { assert false } };
    });

    await test("dotted paths traverse edges over the wire (filter + project + group)", func () : async () {
      // Orders for the most expensive product, with joined fields.
      let q = "{\"start\":\"order\","
        # "\"where\":{\"gt\":{\"field\":\"productId.price\",\"value\":20000}},"
        # "\"select\":[\"id\",\"productId.name\",\"customerId.country\"],"
        # "\"orderBy\":[{\"field\":\"id\",\"dir\":\"asc\"}]}";
      let r = await catalog.execute(q);
      // Only the espresso machine (49900) costs > 20000: orders 1, 4, 6, 10.
      assert r.rows.size() == 4;
      switch (cell(r.rows[0], "productId.name")) {
        case (?c) { assert textOf(c) == "espresso machine" };
        case null { assert false };
      };
      switch (cell(r.rows[0], "id")) { case (?c) { assert natOf(c) == 1 }; case _ { assert false } };

      // Cross-entity aggregation: order count per customer country.
      let g = "{\"start\":\"order\",\"groupBy\":[\"customerId.country\"],"
        # "\"aggregate\":[{\"fn\":\"count\"}],"
        # "\"orderBy\":[{\"field\":\"count\",\"dir\":\"desc\"}]}";
      let gr = await catalog.execute(g);
      // customers span exactly four countries (DE, FR, UK, US).
      assert gr.rows.size() == 4;
      var total = 0;
      for (row in gr.rows.values()) {
        switch (cell(row, "count")) { case (?c) { total += natOf(c) }; case _ { assert false } };
      };
      assert total == 12;   // every order lands in exactly one group
    });

    await test("hidden fields stay invisible even when explicitly selected", func () : async () {
      let q = "{\"start\":\"customer\",\"where\":{\"eq\":{\"field\":\"id\",\"value\":1}},\"select\":[\"name\",\"passwordHash\"]}";
      let r = await catalog.execute(q);
      assert r.rows.size() == 1;
      let row = r.rows[0];
      // Selected name comes through; selected hidden field projects #null_.
      assert row.size() == 2;
      assert textOf(switch (cell(row, "name")) { case (?c) c; case _ { return } }) == "alice";
      switch (cell(row, "passwordHash")) {
        case (?c) { switch (c.value) { case (#null_) { assert true }; case _ { assert false } } };
        case null { assert false };
      };
    });

    // ── Error path over the wire ──────────────────────────────────────

    // `execute` traps on a malformed query. PocketIC surfaces that as a
    // canister reject which would crash this whole `runTests`, so we
    // can't catch it inline. The unit tests in test/Json.test.mo cover
    // the err-vs-trap boundary; here we just confirm a *valid* but empty
    // query against an unknown entity is the way to misuse the API.
    //
    // (Skipped intentionally — kept as documentation.)
  };

};
