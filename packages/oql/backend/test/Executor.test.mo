/// End-to-end tests for the query pipeline (where_ → groupBy/aggregate →
/// orderBy → offset → limit → select), including edge traversal via
/// dotted paths. Builds registries from real `Entity.Builder`s over small
/// in-memory datasets, so this also covers `Entity.build` /
/// `Entity.makeRow` / `Registry.build` / `Registry.lookup`.
///
/// Bypasses `Json.parseQuery` (still a stub) by constructing `Query` AST
/// values directly. That's exactly what the JSON parser would produce.

import {test} "mo:test";
import Iter      "mo:core/Iter";
import Principal "mo:core/Principal";
import OQL      "../src";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

type Customer = { id : Nat; name : Text; country : Text };

let dataset : [Customer] = [
  { id = 1; name = "alice";   country = "DE" },
  { id = 2; name = "bob";     country = "UK" },
  { id = 3; name = "charlie"; country = "DE" },
  { id = 4; name = "dora";    country = "FR" },
];

func registry() : Registry.Registry = Registry.build([
  OQL.Entity.new<Customer>("customer", func () = dataset.values(), "Customer", "id").build(),
]);

// These tests don't exercise authorization; every entity reads unrestricted.
let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

/// Local convenience for the auth-agnostic pipeline tests: run every query
/// with an unrestricted resolver. (The library exposes only `runWith`.)
func run(r : Registry.Registry, q : Query.Query) : Executor.Result =
  Executor.runWith(r, q, unrestricted);

func emptyQuery(start : Text) : Query.Query = {
  start; where_ = null; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select = null;
};

/// Pull the scalar value of one named cell out of a result row.
func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

test("Registry.lookup finds declared entities and returns null otherwise", func () {
  let r = registry();
  // `Entity.Decl` carries function fields, so use pattern-match rather
  // than `== null` (which Motoko refuses on records with closures).
  assert (switch (Registry.lookup(r, "customer")) { case null false; case _ true });
  assert (switch (Registry.lookup(r, "ghost"))    { case null true;  case _ false });
});

test("Registry.schema reflects declared fields in order", func () {
  let doc = Registry.schema(registry(), unrestricted);
  assert doc.entities.size() == 1;
  let e = doc.entities[0];
  assert e.name == "customer";
  assert e.typeName == "Customer";
  assert e.primaryKey == "id";
  assert e.fields.size() == 3;
  // Derived schemas come out in Motoko's canonical (lexicographic) order.
  assert e.fields[0].name == "country";
  assert e.fields[1].name == "id";
  assert e.fields[2].name == "name";
});

test("empty query returns every row, projected with default fields", func () {
  let r = run(registry(), emptyQuery("customer"));
  assert r.rows.size() == 4;
  assert not r.hasMore;
  // Each row carries one cell per non-hidden field (3 here).
  for (row in r.rows.values()) { assert row.size() == 3 };
});

test("where_ filters by predicate", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    where_ = ?(#eq(["country"], #text("DE")))
  };
  let r = run(registry(), q);
  assert r.rows.size() == 2;
  for (row in r.rows.values()) {
    assert cell(row, "country") == ?(#text("DE"));
  };
});

test("orderBy asc / desc sort the result", func () {
  let qAsc : Query.Query = {
    emptyQuery("customer") with
    orderBy = [{ field = ["name"]; dir = #asc }]
  };
  let asc = run(registry(), qAsc);
  assert cell(asc.rows[0], "name") == ?(#text("alice"));
  assert cell(asc.rows[3], "name") == ?(#text("dora"));

  let qDesc : Query.Query = {
    emptyQuery("customer") with
    orderBy = [{ field = ["name"]; dir = #desc }]
  };
  let desc = run(registry(), qDesc);
  assert cell(desc.rows[0], "name") == ?(#text("dora"));
  assert cell(desc.rows[3], "name") == ?(#text("alice"));
});

test("multi-key orderBy uses the second key as tiebreaker", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    orderBy = [
      { field = ["country"]; dir = #asc },
      { field = ["name"];    dir = #asc },
    ];
  };
  let r = run(registry(), q);
  // expected order: (DE, alice), (DE, charlie), (FR, dora), (UK, bob)
  assert cell(r.rows[0], "country") == ?(#text("DE"));
  assert cell(r.rows[0], "name")    == ?(#text("alice"));
  assert cell(r.rows[1], "name")    == ?(#text("charlie"));
  assert cell(r.rows[2], "country") == ?(#text("FR"));
  assert cell(r.rows[3], "country") == ?(#text("UK"));
});

test("offset + limit paginate and flip hasMore correctly", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    orderBy = [{ field = ["id"]; dir = #asc }];
    offset  = ?1;
    limit   = ?2;
  };
  let r = run(registry(), q);
  assert r.rows.size() == 2;
  assert cell(r.rows[0], "id") == ?(#nat(2));
  assert cell(r.rows[1], "id") == ?(#nat(3));
  // Two rows remain after our window (ids 1 was skipped, 4 was clipped),
  // so hasMore must be true.
  assert r.hasMore;
});

test("hasMore is false when the window covers everything", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    limit = ?10
  };
  let r = run(registry(), q);
  assert r.rows.size() == 4;
  assert not r.hasMore;
});

test("select projects only the requested paths", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    orderBy = [{ field = ["id"]; dir = #asc }];
    select  = ?[["id"], ["country"]];
  };
  let r = run(registry(), q);
  for (row in r.rows.values()) {
    assert row.size() == 2;
    assert row[0].name == "id";
    assert row[1].name == "country";
  };
});

// A record whose top-level `lat` collides with a flattened nested
// record's `lat`. Exercises the `__N` discriminator in `Entity.fullRow`.
type Geo   = { lat : Int; lon : Int };
type Place = { id : Nat; lat : Int; geo : Geo };

let places : [Place] = [
  { id = 1; lat = 10; geo = { lat = 99; lon = 20 } },
];

func placeRegistry() : Registry.Registry = Registry.build([
  OQL.Entity.manual<Place>("place", func () = places.values(), "Place", "id")
    .payload("id",  func p = p.id)
    .payload("lat", func p = p.lat)   // first "lat"
    .flatten(func p = p.geo)          // geo.lat collides → "lat__1", plus "lon"
    .build(),
]);

test("colliding column names get a __N discriminator instead of silently dropping", func () {
  let doc = Registry.schema(placeRegistry(), unrestricted);
  let e = doc.entities[0];
  func has(name : Text) : Bool {
    for (f in e.fields.values()) { if (f.name == name) return true };
    false
  };
  // top-level `lat` keeps its name; the flattened geo.lat becomes `lat__1`.
  assert has("id");
  assert has("lat");
  assert has("lat__1");
  assert has("lon");
  // four distinct columns — nothing dropped despite the lat/lat collision.
  assert e.fields.size() == 4;

  // both colliding values survive, addressable under their distinct names.
  let r = run(placeRegistry(), emptyQuery("place"));
  assert r.rows.size() == 1;
  assert cell(r.rows[0], "lat")    == ?(#int(10));   // Place.lat
  assert cell(r.rows[0], "lat__1") == ?(#int(99));   // Place.geo.lat
  assert cell(r.rows[0], "lon")    == ?(#int(20));
});

// Auto-derivation over Principal + sized Nat/Int widths. Each field type
// resolves a shipped `_toRow` instance, so a plain record of them rides
// `Entity.new` with no manual `.payload`.
type Wide = {
  id    : Nat;
  owner : Principal;
  small : Nat8;
  big   : Nat64;
  delta : Int32;
};

let wideOwner = Principal.fromText("aaaaa-aa");
let wides : [Wide] = [
  { id = 1; owner = wideOwner; small = 7; big = 9_000_000_000; delta = -5 },
];

func wideRegistry() : Registry.Registry = Registry.build([
  OQL.Entity.new<Wide>("wide", func () = wides.values(), "Wide", "id").build(),
]);

test("auto-derives Principal and sized Nat/Int widths onto scalar variants", func () {
  let doc = wideRegistry();
  let e = (Registry.schema(doc, unrestricted)).entities[0];
  func typeOf(name : Text) : Text {
    for (f in e.fields.values()) { if (f.name == name) return f.typeName };
    "?"
  };
  // Principal → Text; sized Nats → Nat; sized Ints → Int.
  assert typeOf("owner") == "Text";
  assert typeOf("small") == "Nat";
  assert typeOf("big")   == "Nat";
  assert typeOf("delta") == "Int";

  let r = run(wideRegistry(), emptyQuery("wide"));
  assert r.rows.size() == 1;
  assert cell(r.rows[0], "owner") == ?(#text(Principal.toText(wideOwner)));
  assert cell(r.rows[0], "small") == ?(#nat(7));
  assert cell(r.rows[0], "big")   == ?(#nat(9_000_000_000));
  assert cell(r.rows[0], "delta") == ?(#int(-5));
});

test("count aggregate over all rows returns a single tally row", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    aggregate = [{ fn = #count; field = null; as_ = null }]
  };
  let r = run(registry(), q);
  assert r.rows.size() == 1;
  assert cell(r.rows[0], "count") == ?(#nat(4));
});

test("count over an empty filter result is zero, not an empty result", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    where_ = ?(#eq(["country"], #text("ZZ")));
    aggregate = [{ fn = #count; field = null; as_ = null }];
  };
  let r = run(registry(), q);
  assert r.rows.size() == 1;
  assert cell(r.rows[0], "count") == ?(#nat(0));
});

test("groupBy with count + ordering finds who has the most", func () {
  // group customers by country, count each, most-populous first.
  let q : Query.Query = {
    emptyQuery("customer") with
    groupBy   = [["country"]];
    aggregate = [{ fn = #count; field = null; as_ = null }];
    orderBy   = [{ field = ["count"]; dir = #desc }];
  };
  let r = run(registry(), q);
  // DE (2), then FR (1) / UK (1).
  assert r.rows.size() == 3;
  assert cell(r.rows[0], "country") == ?(#text("DE"));
  assert cell(r.rows[0], "count")   == ?(#nat(2));
  // each grouped row carries exactly the group key + the aggregate.
  assert r.rows[0].size() == 2;
});

test("groupBy with min/max over the grouped id values", func () {
  let q : Query.Query = {
    emptyQuery("customer") with
    groupBy   = [["country"]];
    aggregate = [
      { fn = #min; field = ?["id"]; as_ = null },
      { fn = #max; field = ?["id"]; as_ = ?"hi" },
    ];
    orderBy   = [{ field = ["country"]; dir = #asc }];
  };
  let r = run(registry(), q);
  assert r.rows.size() == 3;
  // DE has ids 1 and 3.
  assert cell(r.rows[0], "country") == ?(#text("DE"));
  assert cell(r.rows[0], "min_id")  == ?(#nat(1));
  assert cell(r.rows[0], "hi")      == ?(#nat(3));   // custom `as` name
});

// ── Edge traversal (dotted paths) ─────────────────────────────────────────
//
// dept : Text FK -> dept.name (Text PK).  "ghost" is dangling.
// boss : Int  FK -> emp.id    (Nat  PK) — exercises the Int/Nat joinKey
// bridge and the self-edge.  -1 is dangling.
// mentor : a #null_ FK on ann (null -> left-join null; also makes the
// seed-derived FK typeName "Null", deferring joinability to runtime).

type Dept = { name : Text; budget : Nat };
type Emp  = { id : Nat; name : Text; salary : Nat; dept : Text; boss : Int };

let depts : [Dept] = [
  { name = "eng"; budget = 100 },
  { name = "ops"; budget = 50 },
];
let emps : [Emp] = [
  { id = 1; name = "ann"; salary = 10; dept = "eng";   boss = -1 },
  { id = 2; name = "bob"; salary = 20; dept = "eng";   boss = 1 },
  { id = 3; name = "cat"; salary = 30; dept = "ops";   boss = 1 },
  { id = 4; name = "dan"; salary = 40; dept = "ghost"; boss = 2 },
];

func joinRegistry() : Registry.Registry = Registry.build([
  OQL.Entity.new<Dept>("dept", func () = depts.values(), "Dept", "name").build(),
  OQL.Entity.new<Emp>("emp", func () = emps.values(), "Emp", "id")
    .payload("mentor", func (e : Emp) : OQL.Value = if (e.id == 1) #null_ else #nat(1),
             func (v : OQL.Value) : OQL.Value = v)
    .edge("dept", "dept")
    .edge("boss", "emp")
    .edge("mentor", "emp")
    .build(),
]);

test("where on a dotted path filters through the edge (left-join + filter)", func () {
  let q : Query.Query = {
    emptyQuery("emp") with
    where_  = ?(#gt(["dept", "budget"], #nat(60)));
    orderBy = [{ field = ["name"]; dir = #asc }];
    select  = ?[["name"], ["dept", "budget"]];
  };
  let r = run(joinRegistry(), q);
  // eng (100) only; cat is ops (50), dan's dept is dangling -> null fails gt.
  assert r.rows.size() == 2;
  assert cell(r.rows[0], "name") == ?(#text("ann"));
  assert cell(r.rows[0], "dept.budget") == ?(#nat(100));
  assert cell(r.rows[1], "name") == ?(#text("bob"));
});

test("dangling and null FKs project as null", func () {
  let q : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#eq(["name"], #text("dan")));
    select = ?[["dept", "budget"], ["mentor", "name"]];
  };
  let r = run(joinRegistry(), q);
  assert r.rows.size() == 1;
  assert cell(r.rows[0], "dept.budget") == ?(#null_);   // dangling "ghost"
  assert cell(r.rows[0], "mentor.name") == ?(#text("ann"));
  // ann's mentor is #null_ -> left-join null.
  let q2 : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#eq(["name"], #text("ann")));
    select = ?[["mentor", "name"]];
  };
  assert cell(run(joinRegistry(), q2).rows[0], "mentor.name") == ?(#null_);
});

test("Int FK joins Nat PK; two edges in one query; two-hop self-edge", func () {
  let q : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#eq(["name"], #text("dan")));
    select = ?[["boss", "name"], ["boss", "boss", "name"], ["dept", "budget"]];
  };
  let r = run(joinRegistry(), q);
  assert cell(r.rows[0], "boss.name")      == ?(#text("bob"));   // #int 2 -> #nat 2
  assert cell(r.rows[0], "boss.boss.name") == ?(#text("ann"));   // two hops
  // ann's boss is -1: dangling.
  let q2 : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#eq(["name"], #text("ann")));
    select = ?[["boss", "name"]];
  };
  assert cell(run(joinRegistry(), q2).rows[0], "boss.name") == ?(#null_);
});

test("aggregate over a dotted field is row-weighted (start-entity rows)", func () {
  // sum of dept.budget over ALL employees: ann+bob see 100 each, cat 50,
  // dan's dangling dept contributes nothing -> 250 (not 150, the sum over
  // departments). Documents the "aggregate from the many side" semantics.
  let q : Query.Query = {
    emptyQuery("emp") with
    aggregate = [{ fn = #sum; field = ?["dept", "budget"]; as_ = ?"b" }]
  };
  let r = run(joinRegistry(), q);
  assert cell(r.rows[0], "b") == ?(#nat(250));
});

test("default name of an aggregate over a dotted field is referencable", func () {
  // sum over ["dept","budget"] defaults to "sum_dept_budget" (joined with
  // '_', not '.') — a dotted default would trap as an edge path here.
  let q : Query.Query = {
    emptyQuery("emp") with
    groupBy   = [["dept"]];
    aggregate = [{ fn = #sum; field = ?["dept", "budget"]; as_ = null }];
    orderBy   = [{ field = ["sum_dept_budget"]; dir = #desc }];
    limit     = ?1;
  };
  let r = run(joinRegistry(), q);
  // eng group: two employees x budget 100 = 200.
  assert cell(r.rows[0], "dept") == ?(#text("eng"));
  assert cell(r.rows[0], "sum_dept_budget") == ?(#nat(200));
});

test("in and text-search predicates work over dotted paths", func () {
  let qIn : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#in_(["dept", "name"], [#text("eng"), #text("nope")]));
  };
  assert run(joinRegistry(), qIn).rows.size() == 2;   // ann, bob

  let qText : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#icontains(["boss", "name"], #text("AN")));     // ann
  };
  assert run(joinRegistry(), qText).rows.size() == 2; // bob, cat
});

test("groupBy on a dotted path + aggregate (the headline query)", func () {
  let q : Query.Query = {
    emptyQuery("emp") with
    groupBy   = [["dept", "budget"]];
    aggregate = [{ fn = #avg; field = ?["salary"]; as_ = ?"avg_salary" }];
    orderBy   = [{ field = ["dept", "budget"]; dir = #desc }];
    limit     = ?2;
  };
  let r = run(joinRegistry(), q);
  // groups: budget 100 (ann+bob -> 15), 50 (cat -> 30), null (dan -> 40);
  // desc puts the real budgets first. orderBy on the dotted group key
  // exercises rowOf's textual path matching + base-first resolution.
  assert r.rows.size() == 2;
  assert cell(r.rows[0], "dept.budget") == ?(#nat(100));
  assert cell(r.rows[0], "avg_salary")  == ?(#float(15.0));
  assert cell(r.rows[1], "dept.budget") == ?(#nat(50));
  assert cell(r.rows[1], "avg_salary")  == ?(#float(30.0));
});

test("groupBy on an edge FK still traverses in select (wrapped agg rows)", func () {
  let q : Query.Query = {
    emptyQuery("emp") with
    groupBy   = [["dept"]];
    aggregate = [{ fn = #count; field = null; as_ = null }];
    orderBy   = [{ field = ["count"]; dir = #desc }];
    select    = ?[["dept"], ["dept", "budget"], ["count"]];
  };
  let r = run(joinRegistry(), q);
  assert r.rows.size() == 3;
  assert cell(r.rows[0], "dept")        == ?(#text("eng"));
  assert cell(r.rows[0], "dept.budget") == ?(#nat(100));   // traversed from FK group key
  assert cell(r.rows[0], "count")       == ?(#nat(2));
  // dangling FK group ("ghost") traverses to null, not a trap.
  for (row in r.rows.values()) {
    if (cell(row, "dept") == ?(#text("ghost"))) {
      assert cell(row, "dept.budget") == ?(#null_);
    };
  };
});

test("edge into an empty entity (no seed) is a left-join null, not a trap", func () {
  type Tag = { id : Text };
  let noTags : [Tag] = [];
  let r = Registry.build([
    OQL.Entity.new<Tag>("tag", func () = noTags.values(), "Tag", "id").build(),
    OQL.Entity.new<Emp>("emp", func () = emps.values(), "Emp", "id")
      .payload("tag", func (_ : Emp) : OQL.Value = #text("t1"),
               func (v : OQL.Value) : OQL.Value = v)
      .edge("tag", "tag")
      .build(),
  ]);
  let q : Query.Query = {
    emptyQuery("emp") with
    where_ = ?(#eq(["name"], #text("ann")));
    select = ?[["tag", "id"]];
  };
  // tag has fields == [] (no rows, no sample): validation skips PK/type
  // checks, the index is empty, traversal resolves null.
  assert cell(run(r, q).rows[0], "tag.id") == ?(#null_);
});

test("complex where_: nested and_/or_/not_", func () {
  // (country=DE OR country=FR) AND NOT (name=charlie)
  let q : Query.Query = {
    emptyQuery("customer") with
    where_ = ?(#and_([
      #or_([
        #eq(["country"], #text("DE")),
        #eq(["country"], #text("FR")),
      ]),
      #not_(#eq(["name"], #text("charlie"))),
    ]));
    orderBy = [{ field = ["name"]; dir = #asc }];
  };
  let r = run(registry(), q);
  assert r.rows.size() == 2;
  assert cell(r.rows[0], "name") == ?(#text("alice"));
  assert cell(r.rows[1], "name") == ?(#text("dora"));
});
