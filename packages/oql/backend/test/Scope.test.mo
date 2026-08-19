/// Unit tests for per-entity authorization in the executor. Drives
/// `Executor.runWith` directly with an injected `access` resolver, so every
/// decision (#unrestricted / #scoped / #deny) is exercised without needing
/// a real canister caller. Datasets carry an `owner : Principal` column
/// declared with `.ownedBy("owner")`. Covers:
///
///   • a #scoped subject sees only its own rows (start entity)
///   • #unrestricted sees every row; `run` delegates to it
///   • edge traversal is scoped too — a join from one owner's rows cannot
///     surface another owner's target rows (the buildIndex leak fix)
///   • a #deny join target contributes an empty index — traversal into it
///     is a left-join null (no leak)
///   • the owner column is tagged role `#owner` in the schema

import {test}    "mo:test";
import Principal "mo:core/Principal";
import OQL      "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _Entity "../src/Entity";
import _BoolValue "../src/BoolValue";
import _NatValue "../src/NatValue";
import _PrincipalValue "../src/PrincipalValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";
import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";
import Predicate "../src/Predicate";
import SecondaryIndex "../src/SecondaryIndex";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

type Note   = { id : Nat; owner : Principal; body : Text; folderId : Nat };
type Folder = { id : Nat; owner : Principal; name : Text };

let pA = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let pB = Principal.fromText("ryjl3-tyaaa-aaaaa-aaaba-cai");

let notes : [Note] = [
  { id = 1; owner = pA; body = "a1"; folderId = 10 },
  { id = 2; owner = pA; body = "a2"; folderId = 10 },
  { id = 3; owner = pB; body = "b1"; folderId = 11 },
  // A's note pointing at B's folder — the leak probe: under A's scope the
  // folder index must not contain folder 11, so this resolves to null.
  { id = 4; owner = pA; body = "a3"; folderId = 11 },
];

let folders : [Folder] = [
  { id = 10; owner = pA; name = "A-folder" },
  { id = 11; owner = pB; name = "B-folder" },
];

func reg() : Registry.Registry = Registry.build([
  OQL.Entity.new<Note>("note", func () = notes.values(), "Note", "id")
    .edge("folderId", "folder")
    .ownedBy("owner")
    .scopedPerUser()
    .build(),
  OQL.Entity.new<Folder>("folder", func () = folders.values(), "Folder", "id")
    .ownedBy("owner")
    .scopedPerUser()
    .build(),
]);

// Resolver helpers: map every entity to one decision.
func scoped(p : Principal) : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #scoped p;
let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func q(start : Text, select : ?[[Text]]) : Query.Query = {
  start; where_ = null; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select;
};

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

func ownerIs(row : [Executor.Cell], p : Principal) : Bool =
  cell(row, "owner") == ?(#text(Principal.toText(p)));

test("scoped to A returns only A's notes", func () {
  let r = Executor.runWith(reg(), q("note", null), scoped(pA));
  assert r.rows.size() == 3;   // notes 1, 2, 4
  for (row in r.rows.values()) { assert ownerIs(row, pA) };
});

test("scoped to B returns only B's notes", func () {
  let r = Executor.runWith(reg(), q("note", null), scoped(pB));
  assert r.rows.size() == 1;   // note 3
  for (row in r.rows.values()) { assert ownerIs(row, pB) };
});

test("unrestricted returns every note", func () {
  let r = Executor.runWith(reg(), q("note", null), unrestricted);
  assert r.rows.size() == 4;
});

test("edge traversal is scoped — no leak across owners", func () {
  let sel : ?[[Text]] = ?[["id"], ["folderId", "name"]];
  let r = Executor.runWith(reg(), q("note", sel), scoped(pA));
  assert r.rows.size() == 3;   // A's notes 1, 2, 4
  for (row in r.rows.values()) {
    let folderName = cell(row, "folderId.name");
    switch (cell(row, "id")) {
      // note 4 points at B's folder; under A's scope the folder index
      // excludes it, so the dotted path is a left-join null — not "B-folder".
      case (?(#nat 4)) { assert folderName == ?(#null_) };
      case _           { assert folderName == ?(#text("A-folder")) };
    };
  };
});

test("a denied join target is an empty index — traversal is null", func () {
  // note is unrestricted, but folder is denied for this caller: every
  // folder traversal must resolve to null, even though notes are visible.
  let denyFolder : Executor.Access =
    func (d : OQL.Decl) : OQL.Access = if (d.name == "folder") #deny else #unrestricted;
  let sel : ?[[Text]] = ?[["id"], ["folderId", "name"]];
  let r = Executor.runWith(reg(), q("note", sel), denyFolder);
  assert r.rows.size() == 4;   // all notes visible
  for (row in r.rows.values()) { assert cell(row, "folderId.name") == ?(#null_) };
});

test("a denied start entity traps", func () {
  // Can't catch a trap synchronously; the replica suite asserts this path.
  // Here we only assert the allowed counterpart compiles and runs.
  assert Executor.runWith(reg(), q("note", null), unrestricted).rows.size() == 4;
});

test("a folder query is itself scoped to the caller", func () {
  assert Executor.runWith(reg(), q("folder", null), scoped(pA)).rows.size() == 1; // folder 10
  assert Executor.runWith(reg(), q("folder", null), scoped(pB)).rows.size() == 1; // folder 11
  assert Executor.runWith(reg(), q("folder", null), unrestricted).rows.size() == 2;
});

test("owner column is tagged role #owner in the schema", func () {
  let doc = Registry.schema(reg(), unrestricted);
  var checked = false;
  for (e in doc.entities.values()) {
    if (e.name == "note") {
      for (f in e.fields.values()) {
        if (f.name == "owner") {
          checked := true;
          assert (switch (f.role) { case (#owner) true; case _ false });
        };
      };
    };
  };
  assert checked;
});

// ── Custom ownership scheme via .ownedByWith ────────────────────────────
// The owner column is a TEAM id (not a principal); an app-provided
// predicate decides visibility by team membership — overriding the
// default principal-equality scheme. Composes with a scoped level.

type Doc = { id : Nat; team : Text; title : Text };

let pC = Principal.fromText("r7inp-6aaaa-aaaaa-aaabq-cai");  // belongs to no team

let teamDocs : [Doc] = [
  { id = 1; team = "alpha";  title = "A1" },
  { id = 2; team = "beta";   title = "B1" },
  { id = 3; team = "shared"; title = "S1" },
  { id = 4; team = "ghost";  title = "nobody's" },
];

// pA -> {alpha, shared}; pB -> {beta}; everyone else -> {}
func teamsOf(p : Principal) : [Text] =
  if (p == pA) { ["alpha", "shared"] }
  else if (p == pB) { ["beta"] }
  else { [] };

func onTeam(subject : Principal, owner : OQL.Value) : Bool =
  switch owner {
    case (#text team) { teamsOf(subject).values().any(func (t : Text) : Bool = t == team) };
    case _ { false };
  };

func treg() : Registry.Registry = Registry.build([
  OQL.Entity.new<Doc>("doc", func () = teamDocs.values(), "Doc", "id")
    .ownedByWith("team", onTeam)
    .scopedPerUser()
    .build(),
]);

test("custom predicate scopes by team membership, not principal identity", func () {
  // pA is on alpha + shared → docs 1 and 3.
  let ra = Executor.runWith(treg(), q("doc", null), scoped(pA));
  assert ra.rows.size() == 2;
  for (row in ra.rows.values()) {
    let team = cell(row, "team");
    assert (team == ?(#text("alpha")) or team == ?(#text("shared")));
  };
  // pB is on beta → doc 2 only.
  assert Executor.runWith(treg(), q("doc", null), scoped(pB)).rows.size() == 1;
  // pC is on no team → sees nothing.
  assert Executor.runWith(treg(), q("doc", null), scoped(pC)).rows.size() == 0;
  // unrestricted still sees every doc, custom predicate bypassed.
  assert Executor.runWith(treg(), q("doc", null), unrestricted).rows.size() == 4;
});

test("a custom-scheme owner column is still tagged role #owner", func () {
  let doc = Registry.schema(treg(), unrestricted);
  var checked = false;
  for (e in doc.entities.values()) {
    for (f in e.fields.values()) {
      if (f.name == "team") {
        checked := true;
        assert (switch (f.role) { case (#owner) true; case _ false });
      };
    };
  };
  assert checked;
});

// ── newScoped: already O(subject rows); no served path may reach a scoped read ──
// The source itself is subject-keyed, so a scoped read iterates ONE bucket and
// applies no owner filter. These pins hold the executor to that: (1) the
// behavioral contract, (2) the subject-null gates — a hand-attached Served
// whose every accessor traps must never be consulted by a scoped read, even
// though it advertises an index for every column.


type Task = { id : Nat; title : Text };

func bucketOf(p : ?Principal) : [Task] = switch p {
  case (?q) {
    if (q == pA) [{ id = 1; title = "a1" }, { id = 2; title = "a2" }]
    else if (q == pB) [{ id = 3; title = "b1" }]
    else [];
  };
  // null = unrestricted: every bucket (schema seeding + controller reads)
  case null [{ id = 1; title = "a1" }, { id = 2; title = "a2" }, { id = 3; title = "b1" }];
};

func hostileServed() : _Entity.Served = {
  kindOf = func (_ : Text) : ?SecondaryIndex.Kind = ?#ordered;   // advertises every column
  point  = func (_ : Text, _ : OQL.Value) : Iter.Iter<Predicate.Row> = Runtime.trap("hostile Served consulted: point");
  points = func (_ : Text, _ : [OQL.Value]) : Iter.Iter<Predicate.Row> = Runtime.trap("hostile Served consulted: points");
  range  = func (_ : Text, _ : ?OQL.Value, _ : ?OQL.Value, _ : _Entity.Dir) : Iter.Iter<Predicate.Row> = Runtime.trap("hostile Served consulted: range");
  composites = null;
  stats  = null;
  prune  = ?(func (_ : ?OQL.Predicate) : Iter.Iter<Predicate.Row> = Runtime.trap("hostile Served consulted: prune"));
};

// Hostile Served attached: an UNRESTRICTED read may legitimately consult it
// (and would trap), so unrestricted assertions use the clean registry below.
func sreg() : Registry.Registry = Registry.build([
  OQL.Entity.newScoped<Task>("task", func (p : ?Principal) = bucketOf(p).values(), "Task", "id")
    .scopedPerUser()
    .withServed(func (_ : Task -> Predicate.Row) : _Entity.Served = hostileServed())
    .build(),
]);
func cleanSreg() : Registry.Registry = Registry.build([
  OQL.Entity.newScoped<Task>("task", func (p : ?Principal) = bucketOf(p).values(), "Task", "id")
    .scopedPerUser()
    .build(),
]);

test("newScoped: each scoped caller sees exactly its own bucket", func () {
  let ra = Executor.runWith(sreg(), q("task", null), scoped(pA));
  assert ra.rows.size() == 2;
  let rb = Executor.runWith(sreg(), q("task", null), scoped(pB));
  assert rb.rows.size() == 1;
  assert cell(rb.rows[0], "id") == ?(#nat 3);
  assert Executor.runWith(cleanSreg(), q("task", null), unrestricted).rows.size() == 3;
});

test("newScoped: a scoped read never consults a Served — sargable predicate included", func () {
  // #eq on an "indexed" column would seek the hostile Served and trap if the
  // subject-null gates ever loosened for subject-honouring sources.
  let qq : Query.Query = {
    start = "task"; where_ = ?(#eq(["id"], #nat(3))); groupBy = []; aggregate = [];
    orderBy = []; offset = null; limit = null; select = null;
  };
  assert Executor.runWith(sreg(), qq, scoped(pA)).rows.size() == 0;   // not A's row
  assert Executor.runWith(sreg(), qq, scoped(pB)).rows.size() == 1;   // B's own
  // A scoped aggregate folds the bucket, never stats:
  let cq : Query.Query = {
    start = "task"; where_ = null; groupBy = []; aggregate = [{ fn = #count; field = null; as_ = null }];
    orderBy = []; offset = null; limit = null; select = null;
  };
  assert cell(Executor.runWith(sreg(), cq, scoped(pA)).rows[0], "count") == ?(#nat 2);
});
