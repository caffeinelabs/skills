/// End-to-end PocketIC test driving the `Library` fixture, which uses
/// three different collection shapes (`[Author]`, `List.List<Article>`,
/// `Set.Set<Text>`) and exposes records with nested sub-records and
/// collection-typed fields. The point is to prove OQL is orthogonal to
/// the developer's storage choice and that the `extract` closures can
/// flatten anything they like into OQL's scalar vocabulary.
///
/// Together the assertions exercise:
///
///   • iterating an immutable `[T]` source
///   • iterating a `List.List<T>` source
///   • iterating a `Set.Set<T>` source (with no record at all — the
///     element IS the row)
///   • predicates over fields flattened from nested records
///     (`address.city` → `city`, `reactions.likes` → `likes`)
///   • predicates over fields derived from collection fields
///     (`tags.size()` → `tagCount`, body words → `wordCount`)
///   • predicates over a variant-flattened-to-text field (`status`)
///   • mixing all three sources in one schema response

import {test}  "mo:test/async";
import Text    "mo:core/Text";
import Library "./fixtures/Library";

actor {

  // ── String search helpers ────────────────────────────────────────────

  func contains(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));

  // ── Result helpers ───────────────────────────────────────────────────

  type Cell = { name : Text; value : { #null_; #bool : Bool; #nat : Nat; #int : Int; #float : Float; #text : Text } };

  func cell(row : [Cell], name : Text) : ?Cell {
    for (c in row.values()) { if (c.name == name) return ?c };
    null
  };

  func natOf(c : Cell) : Nat = switch (c.value) {
    case (#nat n) n;
    case _ 0;
  };

  func textOf(c : Cell) : Text = switch (c.value) {
    case (#text t) t;
    case _ "";
  };

  // ── Tests ────────────────────────────────────────────────────────────

  public func runTests() : async () {

    let library = await (with cycles = 10_000_000_000_000) Library.Library();

    // ── Schema sees all three entities, despite three storage shapes ──

    await test("schema lists every entity regardless of storage shape", func () : async () {
      let json = await library.schema();
      assert contains(json, "\"name\":\"author\"");
      assert contains(json, "\"name\":\"article\"");
      assert contains(json, "\"name\":\"tag\"");
      assert contains(json, "\"name\":\"archived\"");
      assert contains(json, "\"name\":\"measurement\"");
    });

    await test("schema surfaces a declared variant domain as field values", func () : async () {
      let json = await library.schema();
      // article.status is a variant; its arms are declared via .domain(...)
      assert contains(json, "\"values\":[\"draft\",\"published\",\"archived\"]");
    });

    await test("schema surfaces flattened nested fields with their own names", func () : async () {
      let json = await library.schema();
      // Author derived from nested Address record:
      assert contains(json, "\"name\":\"city\"");
      assert contains(json, "\"name\":\"country\"");
      // Article derived from nested Reactions record:
      assert contains(json, "\"name\":\"likes\"");
      assert contains(json, "\"name\":\"shares\"");
      assert contains(json, "\"name\":\"comments\"");
      // Derived from a collection:
      assert contains(json, "\"name\":\"tagCount\"");
      assert contains(json, "\"name\":\"coAuthorCount\"");
    });

    // ── Querying the immutable array ([Author]) ───────────────────────

    await test("filter authors by nested-record field (city)", func () : async () {
      let q = "{\"start\":\"author\",\"where\":{\"eq\":{\"field\":\"city\",\"value\":\"Paris\"}}}";
      let r = await library.execute(q);
      assert r.rows.size() == 1;
      switch (cell(r.rows[0], "name")) {
        case (?c) { assert textOf(c) == "Curie" };
        case null { assert false };
      };
    });

    await test("filter authors by derived collection scalar (tagCount >= 3)", func () : async () {
      let q = "{\"start\":\"author\",\"where\":{\"ge\":{\"field\":\"tagCount\",\"value\":3}},"
        # "\"orderBy\":[{\"field\":\"name\",\"dir\":\"asc\"}]}";
      let r = await library.execute(q);
      // Ada (3 tags) and Dijkstra (4 tags) qualify.
      assert r.rows.size() == 2;
      switch (cell(r.rows[0], "name")) { case (?c) { assert textOf(c) == "Ada" };      case _ { assert false } };
      switch (cell(r.rows[1], "name")) { case (?c) { assert textOf(c) == "Dijkstra" }; case _ { assert false } };
    });

    await test("derived text field (joined tags) is queryable and projectable", func () : async () {
      let q = "{\"start\":\"author\",\"where\":{\"eq\":{\"field\":\"name\",\"value\":\"Ada\"}},"
        # "\"select\":[\"name\",\"tagSummary\"]}";
      let r = await library.execute(q);
      assert r.rows.size() == 1;
      let row = r.rows[0];
      assert row.size() == 2;
      assert textOf(switch (cell(row, "tagSummary")) { case (?c) c; case _ { return } })
             == "math,compsci,engineering";
    });

    // ── Querying the List (List.List<Article>) ────────────────────────

    await test("filter articles by variant-flattened status", func () : async () {
      let q = "{\"start\":\"article\",\"where\":{\"eq\":{\"field\":\"status\",\"value\":\"published\"}}}";
      let r = await library.execute(q);
      // 4 published articles in the seed data
      assert r.rows.size() == 4;
      for (row in r.rows.values()) {
        switch (cell(row, "status")) { case (?c) { assert textOf(c) == "published" }; case _ { assert false } };
      };
    });

    await test("filter articles by nested-record numeric (likes >= 1000) + orderBy desc", func () : async () {
      let q = "{\"start\":\"article\","
        # "\"where\":{\"ge\":{\"field\":\"likes\",\"value\":1000}},"
        # "\"orderBy\":[{\"field\":\"likes\",\"dir\":\"desc\"}]}";
      let r = await library.execute(q);
      // Two articles cross the 1000-like mark: Go-to (3200), Forking Paths (1800).
      assert r.rows.size() == 2;
      switch (cell(r.rows[0], "title")) { case (?c) { assert textOf(c) == "Go-to considered harmful" }; case _ { assert false } };
      switch (cell(r.rows[1], "title")) { case (?c) { assert textOf(c) == "Garden of Forking Paths" }; case _ { assert false } };
    });

    await test("multi-key orderBy across two derived/nested fields", func () : async () {
      // Group by status (published / draft / archived) ascending,
      // then by wordCount descending within each group.
      let q = "{\"start\":\"article\",\"orderBy\":["
        # "{\"field\":\"status\",\"dir\":\"asc\"},"
        # "{\"field\":\"wordCount\",\"dir\":\"desc\"}]}";
      let r = await library.execute(q);
      assert r.rows.size() == 6;
      // Status sorts lexicographically: archived, draft, published.
      switch (cell(r.rows[0], "status")) { case (?c) { assert textOf(c) == "archived" }; case _ { assert false } };
      switch (cell(r.rows[1], "status")) { case (?c) { assert textOf(c) == "draft" };    case _ { assert false } };
      switch (cell(r.rows[2], "status")) { case (?c) { assert textOf(c) == "published" }; case _ { assert false } };
    });

    await test("filter by coAuthorCount derived from an array field", func () : async () {
      let q = "{\"start\":\"article\",\"where\":{\"gt\":{\"field\":\"coAuthorCount\",\"value\":0}}}";
      let r = await library.execute(q);
      assert r.rows.size() == 1;  // only "Go-to considered harmful" has co-authors
      switch (cell(r.rows[0], "title")) { case (?c) { assert textOf(c) == "Go-to considered harmful" }; case _ { assert false } };
    });

    await test("edge field surfaces foreign-key id from list-backed entity", func () : async () {
      let q = "{\"start\":\"article\",\"where\":{\"eq\":{\"field\":\"id\",\"value\":4}}}";
      let r = await library.execute(q);
      assert r.rows.size() == 1;
      switch (cell(r.rows[0], "authorId")) {
        case (?c) { assert natOf(c) == 3 };  // Curie wrote Radioactivity
        case null { assert false };
      };
    });

    // ── Aggregation (count / groupBy) over the JSON wire ──────────────

    await test("aggregate: groupBy status + count, ordered, via JSON", func () : async () {
      let q = "{\"start\":\"article\",\"groupBy\":[\"status\"],"
        # "\"aggregate\":[{\"fn\":\"count\"}],"
        # "\"orderBy\":[{\"field\":\"count\",\"dir\":\"desc\"}]}";
      let r = await library.execute(q);
      // three distinct statuses; published (4) is the largest group.
      assert r.rows.size() == 3;
      switch (cell(r.rows[0], "status")) { case (?c) { assert textOf(c) == "published" }; case _ { assert false } };
      switch (cell(r.rows[0], "count"))  { case (?c) { assert natOf(c) == 4 };           case _ { assert false } };
      // grouped row carries exactly the group key + the aggregate.
      assert r.rows[0].size() == 2;
    });

    await test("aggregate: bare count over a filtered set via JSON", func () : async () {
      let q = "{\"start\":\"article\","
        # "\"where\":{\"ge\":{\"field\":\"likes\",\"value\":1000}},"
        # "\"aggregate\":[{\"fn\":\"count\"}]}";
      let r = await library.execute(q);
      assert r.rows.size() == 1;
      // Go-to (3200) + Forking Paths (1800) cross 1000 likes.
      switch (cell(r.rows[0], "count")) { case (?c) { assert natOf(c) == 2 }; case _ { assert false } };
    });

    // ── Querying the Set (Set.Set<Text>) ──────────────────────────────

    await test("enumerate tag entity (set-backed, element IS the row)", func () : async () {
      let q = "{\"start\":\"tag\",\"orderBy\":[{\"field\":\"name\",\"dir\":\"asc\"}]}";
      let r = await library.execute(q);
      // Set dedupes: math, compsci, engineering, fiction, philosophy,
      // physics, chemistry → 7 unique tags.
      assert r.rows.size() == 7;
      // Ascending lexicographic order of distinct tags.
      switch (cell(r.rows[0], "name")) { case (?c) { assert textOf(c) == "chemistry" }; case _ { assert false } };
      switch (cell(r.rows[6], "name")) { case (?c) { assert textOf(c) == "physics" };   case _ { assert false } };
    });

    await test("filter the tag set by exact name match", func () : async () {
      let q = "{\"start\":\"tag\",\"where\":{\"eq\":{\"field\":\"name\",\"value\":\"compsci\"}}}";
      let r = await library.execute(q);
      assert r.rows.size() == 1;
      switch (cell(r.rows[0], "name")) { case (?c) { assert textOf(c) == "compsci" }; case _ { assert false } };
    });

    // ── Querying the [var Article] snapshot ───────────────────────────

    await test("[var T]-backed entity is queryable identically to [T]", func () : async () {
      let q = "{\"start\":\"archived\","
        # "\"where\":{\"eq\":{\"field\":\"status\",\"value\":\"published\"}},"
        # "\"orderBy\":[{\"field\":\"id\",\"dir\":\"asc\"}]}";
      let r = await library.execute(q);
      // Same 4 published rows as the List-backed `article` entity.
      assert r.rows.size() == 4;
      switch (cell(r.rows[0], "title")) { case (?c) { assert textOf(c) == "Note G" }; case _ { assert false } };
    });

    await test("page through the tag set, hasMore flips correctly", func () : async () {
      let p1 = await library.execute(
        "{\"start\":\"tag\",\"orderBy\":[{\"field\":\"name\",\"dir\":\"asc\"}],\"limit\":3}"
      );
      assert p1.rows.size() == 3;
      assert p1.hasMore;

      let p3 = await library.execute(
        "{\"start\":\"tag\",\"orderBy\":[{\"field\":\"name\",\"dir\":\"asc\"}],\"offset\":6,\"limit\":3}"
      );
      assert p3.rows.size() == 1;       // only one tag remains past offset 6
      assert not p3.hasMore;
    });

    // ── Querying the nested Map<Int, Map<Nat, Measurement>> ──────────

    await test("nested map enumerates every (bucket, sensor, measurement) triple", func () : async () {
      let q = "{\"start\":\"measurement\"}";
      let r = await library.execute(q);
      // 3 readings in bucket -1, 4 in bucket 0, 2 in bucket 1 = 9 total.
      assert r.rows.size() == 9;
    });

    await test("filter on a negative outer-map key (signed Int bucket)", func () : async () {
      let q = "{\"start\":\"measurement\",\"where\":{\"eq\":{\"field\":\"bucket\",\"value\":-1}}}";
      let r = await library.execute(q);
      // Three measurements live in bucket -1.
      assert r.rows.size() == 3;
      for (row in r.rows.values()) {
        switch (cell(row, "bucket")) {
          case (?c) {
            switch (c.value) {
              case (#int n) { assert n == -1 };
              // Predicate.compare bridges nat↔int, so an extract that
              // returned #nat would still match the query — but in this
              // fixture we explicitly emit #int.
              case _ { assert false };
            };
          };
          case null { assert false };
        };
      };
    });

    await test("filter on the inner-map key (sensor) crosses every bucket", func () : async () {
      let q = "{\"start\":\"measurement\","
        # "\"where\":{\"eq\":{\"field\":\"sensor\",\"value\":1}},"
        # "\"orderBy\":[{\"field\":\"bucket\",\"dir\":\"asc\"}]}";
      let r = await library.execute(q);
      // Sensor 1 reports in every bucket (-1, 0, 1) = 3 rows.
      assert r.rows.size() == 3;
      for (row in r.rows.values()) {
        switch (cell(row, "sensor")) { case (?c) { switch (c.value) { case (#nat 1) {}; case _ { assert false } } }; case null { assert false } };
      };
    });

    await test("composite filter spanning both map levels + an inner value", func () : async () {
      // bucket >= 0 AND metric = "temp" AND okay = true
      let q = "{\"start\":\"measurement\",\"where\":{\"and\":["
        # "{\"ge\":{\"field\":\"bucket\",\"value\":0}},"
        # "{\"eq\":{\"field\":\"metric\",\"value\":\"temp\"}},"
        # "{\"eq\":{\"field\":\"okay\",\"value\":true}}]}}";
      let r = await library.execute(q);
      // bucket 0 sensor 1: temp 22 / okay=true → matches
      // bucket 1 sensor 1: temp 24 / okay=false → fails
      assert r.rows.size() == 1;
      switch (cell(r.rows[0], "value")) {
        case (?c) { switch (c.value) { case (#nat 22) {}; case _ { assert false } } };
        case null { assert false };
      };
    });

    await test("multi-key orderBy across both map levels", func () : async () {
      // Sort by bucket asc, then by sensor asc within the bucket.
      let q = "{\"start\":\"measurement\",\"orderBy\":["
        # "{\"field\":\"bucket\",\"dir\":\"asc\"},"
        # "{\"field\":\"sensor\",\"dir\":\"asc\"}]}";
      let r = await library.execute(q);
      assert r.rows.size() == 9;
      // First row must be (bucket=-1, sensor=1)
      switch (cell(r.rows[0], "bucket")) { case (?c) { switch (c.value) { case (#int (-1)) {}; case _ { assert false } } }; case _ { assert false } };
      switch (cell(r.rows[0], "sensor")) { case (?c) { switch (c.value) { case (#nat 1)    {}; case _ { assert false } } }; case _ { assert false } };
      // Last row must be (bucket=1, sensor=2)
      switch (cell(r.rows[8], "bucket")) { case (?c) { switch (c.value) { case (#int 1) {}; case _ { assert false } } }; case _ { assert false } };
      switch (cell(r.rows[8], "sensor")) { case (?c) { switch (c.value) { case (#nat 2) {}; case _ { assert false } } }; case _ { assert false } };
    });

  };

};
