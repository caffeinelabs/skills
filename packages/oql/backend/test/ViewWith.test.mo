/// Unit tests for `.viewWith` — per-subject row projection, the value-level
/// cousin of `.ownedByWith`. Where the ownership check decides WHICH rows a
/// scoped subject sees, the view decides what SHAPE it sees them in. These
/// pin the three guarantees the executor relies on:
///
///   • the ownership check evaluates the RAW row, so a view can reshape rows
///     but can never widen or narrow visibility (visibility-stealing view);
///   • views run for concrete (scoped) subjects only — unrestricted reads
///     see raw rows, so the view is a no-op for controllers / `#public_`;
///   • the whole pipeline (where_ / groupBy / aggregate / join traversal
///     INTO the entity) reads the viewed row, so a predicate can't probe a
///     value the view hides via the result shape (no redaction oracle).
///
/// Builds registries from real `Entity.Builder`s and drives `Executor.runWith`
/// with an `Access` resolver that returns `#scoped p` (view runs) or
/// `#unrestricted` (view no-op), bypassing `Auth.resolve` to isolate the view
/// mechanism from the auth-level table.

import {test} "mo:test";
import Principal "mo:core/Principal";
import OQL      "../src";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

type Event = { id : Nat; calendar : Text; title : Text; note : Text };

// Three distinct, non-anonymous principals. `canSee` admits:
//   alice → "cal-a"   (calendar owner — full visibility)
//   bob   → "cal-a"   (freebusy viewer — masked by the view)
//   carol → "cal-c"   (owns a different calendar; not admitted to cal-a)
let alice = Principal.fromText("aaaaa-aa");
let bob   = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
let carol = Principal.fromText("un4fu-tqaaa-aaaab-qadjq-cai");

let events : [Event] = [
  { id = 1; calendar = "cal-a"; title = "Standup";    note = "zoom" },
  { id = 2; calendar = "cal-a"; title = "1:1 w/ CEO"; note = "secret" },
  { id = 3; calendar = "cal-c"; title = "Carol sync"; note = "carol's notes" },
];

/// Row-level admission (the "which rows" half). The owner column is
/// `calendar` (text), not a principal — `.ownedByWith` is happy with any
/// value type as long as `canSee` decides on it.
func canSee(subject : Principal, calendar : OQL.Value) : Bool = switch calendar {
  case (#text c) {
    if (c == "cal-a") { subject == alice or subject == bob }
    else if (c == "cal-c") { subject == carol }
    else { false };
  };
  case _ { false };
};

/// Per-subject projection (the "what shape" half). bob is a freebusy viewer
/// of cal-a, so its events come back as opaque busy blocks; alice (owner)
/// and carol see raw rows.
func view(subject : Principal, e : Event) : Event =
  if (subject == bob) ({ e with title = "Busy"; note = "" }) else e;

/// A hostile view that rewrites the owner column to a calendar the subject
/// IS admitted to ("cal-c" for carol) and flaunts its rewrite in `title`.
/// Used to prove the ownership check ran on the RAW row, so the view can
/// reshape an admitted row but can never smuggle a denied one through.
func hostileView(subject : Principal, e : Event) : Event =
  ({ e with calendar = "cal-c"; title = "STOLEN" });

func eventRegistry() : Registry.Registry = Registry.build([
  OQL.Entity.new<Event>("event", func () = events.values(), "Event", "id")
    .ownedByWith("calendar", canSee)
    .viewWith(view)
    .scopedPerUser()
    .build(),
]);

func hostileRegistry() : Registry.Registry = Registry.build([
  OQL.Entity.new<Event>("eventHostile", func () = events.values(), "Event", "id")
    .ownedByWith("calendar", canSee)
    .viewWith(hostileView)
    .scopedPerUser()
    .build(),
]);

// ── Access resolvers ──────────────────────────────────────────────────────
//
// `Executor.runWith` resolves access per entity: `#scoped p` makes the
// subject concrete (view + ownership check run), `#unrestricted` passes null
// (view no-op). We bypass `Auth.resolve` to test the view mechanism itself.

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func scopedOn(name : Text, p : Principal) : Executor.Access =
  func (d : OQL.Decl) : OQL.Access = if (d.name == name) #scoped p else #unrestricted;

func emptyQuery(start : Text) : Query.Query = {
  start; where_ = null; groupBy = []; aggregate = [];
  orderBy = []; offset = null; limit = null; select = null;
};

func byId(start : Text) : Query.Query = {
  emptyQuery(start) with orderBy = [{ field = ["id"]; dir = #asc }]
};

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

func natOf(v : ?OQL.Value) : Nat = switch v { case (?(#nat n)) n; case _ 0 };
func textOf(v : ?OQL.Value) : Text = switch v { case (?(#text t)) t; case _ "" };

// ── Shape: which rows a subject sees, and in what shape ───────────────────

test("a freebusy viewer sees admitted rows masked, not raw", func () {
  let r = Executor.runWith(eventRegistry(), emptyQuery("event"), scopedOn("event", bob));
  assert r.rows.size() == 2;              // cal-a rows only; cal-c not admitted for bob
  for (row in r.rows.values()) {
    assert textOf(cell(row, "title")) == "Busy";
    assert textOf(cell(row, "note")) == "";
    assert natOf(cell(row, "id")) > 0;    // identity preserved through the view
  };
});

test("the calendar owner sees the same admitted rows raw", func () {
  let r = Executor.runWith(eventRegistry(), byId("event"), scopedOn("event", alice));
  assert r.rows.size() == 2;
  assert textOf(cell(r.rows[0], "title")) == "Standup";
  assert textOf(cell(r.rows[0], "note")) == "zoom";
  assert textOf(cell(r.rows[1], "title")) == "1:1 w/ CEO";
  assert textOf(cell(r.rows[1], "note")) == "secret";
});

test("a subject scoped to a different calendar sees only its own rows raw", func () {
  let r = Executor.runWith(eventRegistry(), emptyQuery("event"), scopedOn("event", carol));
  assert r.rows.size() == 1;              // only the cal-c row
  assert textOf(cell(r.rows[0], "title")) == "Carol sync";
  assert textOf(cell(r.rows[0], "note")) == "carol's notes";
});

test("an unrestricted caller sees every row raw — the view is a no-op", func () {
  let r = Executor.runWith(eventRegistry(), byId("event"), unrestricted);
  assert r.rows.size() == 3;              // null subject → no scoping, no view
  assert textOf(cell(r.rows[0], "title")) == "Standup";      // raw, not "Busy"
  assert textOf(cell(r.rows[1], "title")) == "1:1 w/ CEO";
  assert textOf(cell(r.rows[2], "title")) == "Carol sync";
});

// ── No redaction oracle: the pipeline reads the VIEWED row ────────────────

test("a viewer cannot probe a masked note via where_ (no oracle)", func () {
  let q = { emptyQuery("event") with where_ = ?(#eq(["note"], #text("secret"))) };
  let r = Executor.runWith(eventRegistry(), q, scopedOn("event", bob));
  assert r.rows.size() == 0;              // bob's note is "" — the predicate sees the mask
});

test("the owner CAN filter on the raw note — the mask is subject-specific", func () {
  let q = { emptyQuery("event") with where_ = ?(#eq(["note"], #text("secret"))) };
  let r = Executor.runWith(eventRegistry(), q, scopedOn("event", alice));
  assert r.rows.size() == 1;              // alice sees the raw note "secret"
  assert natOf(cell(r.rows[0], "id")) == 2;
});

test("a viewer CAN filter on the masked value — the mask is the pipeline's truth", func () {
  let q = { emptyQuery("event") with where_ = ?(#eq(["title"], #text("Busy"))) };
  let r = Executor.runWith(eventRegistry(), q, scopedOn("event", bob));
  assert r.rows.size() == 2;              // both cal-a rows mask title to "Busy"
});

// ── Grouping over masks ───────────────────────────────────────────────────

test("groupBy over the masked title collapses to one busy group for the viewer", func () {
  let q : Query.Query = {
    emptyQuery("event") with
    groupBy   = [["title"]];
    aggregate = [{ fn = #count; field = null; as_ = null }];
  };
  let r = Executor.runWith(eventRegistry(), q, scopedOn("event", bob));
  assert r.rows.size() == 1;              // both rows mask to "Busy" → one group
  assert textOf(cell(r.rows[0], "title")) == "Busy";
  assert natOf(cell(r.rows[0], "count")) == 2;
});

test("groupBy over the raw title keeps distinct titles for the owner", func () {
  let q : Query.Query = {
    emptyQuery("event") with
    groupBy   = [["title"]];
    aggregate = [{ fn = #count; field = null; as_ = null }];
  };
  let r = Executor.runWith(eventRegistry(), q, scopedOn("event", alice));
  assert r.rows.size() == 2;              // "Standup" and "1:1 w/ CEO" stay distinct
  for (row in r.rows.values()) {
    assert natOf(cell(row, "count")) == 1;
    assert textOf(cell(row, "title")) != "Busy";   // never masked for the owner
  };
});

// ── Visibility-stealing view can't widen visibility ───────────────────────
//
// carol is admitted to "cal-c" only. The hostile view rewrites every row's
// `calendar` to "cal-c" and `title` to "STOLEN". The two cal-a rows are
// rejected on their RAW calendar before the view runs, so carol sees only
// the one cal-c row (reshaped to "STOLEN") — not the cal-a rows the view
// tried to smuggle in. The view reshapes admitted rows; it can't admit.

test("a view that rewrites the owner column cannot widen visibility", func () {
  let r = Executor.runWith(hostileRegistry(), emptyQuery("eventHostile"), scopedOn("eventHostile", carol));
  assert r.rows.size() == 1;              // only the raw-admitted cal-c row
  assert natOf(cell(r.rows[0], "id")) == 3;
  assert textOf(cell(r.rows[0], "title")) == "STOLEN";    // the view DID run on the admitted row
  assert textOf(cell(r.rows[0], "calendar")) == "cal-c";  // ...and rewrote it
});

// ── Join traversal INTO the viewed entity ─────────────────────────────────
//
// `reminder.event` is a FK into `event`. The join target's rows are fetched
// at the target's OWN resolved access, so a scoped traversal sees the VIEWED
// (masked) event row, and an unrestricted traversal sees the raw one. A
// reminder whose event the scoped subject can't read left-joins to null.

type Reminder = { id : Nat; event : Nat };

let reminders : [Reminder] = [
  { id = 10; event = 1 },
  { id = 11; event = 2 },
  { id = 12; event = 3 },
];

func joinRegistry() : Registry.Registry = Registry.build([
  OQL.Entity.new<Reminder>("reminder", func () = reminders.values(), "Reminder", "id")
    .edge("event", "event")
    .build(),
  OQL.Entity.new<Event>("event", func () = events.values(), "Event", "id")
    .ownedByWith("calendar", canSee)
    .viewWith(view)
    .scopedPerUser()
    .build(),
]);

test("a scoped join INTO the viewed entity reads the masked row", func () {
  let q = { byId("reminder") with select = ?[["event", "title"]] };
  // reminder unrestricted (start); event scoped to bob → masked, bob-admitted only.
  let r = Executor.runWith(joinRegistry(), q, scopedOn("event", bob));
  assert r.rows.size() == 3;
  assert textOf(cell(r.rows[0], "event.title")) == "Busy";   // event 1, bob-admitted → masked
  assert textOf(cell(r.rows[1], "event.title")) == "Busy";   // event 2, bob-admitted → masked
  assert cell(r.rows[2], "event.title") == ?(#null_);        // event 3 on cal-c, bob denied → null
});

test("an unrestricted join INTO the viewed entity reads the raw row", func () {
  let q = { byId("reminder") with select = ?[["event", "title"]] };
  let r = Executor.runWith(joinRegistry(), q, unrestricted);
  assert r.rows.size() == 3;
  assert textOf(cell(r.rows[0], "event.title")) == "Standup";
  assert textOf(cell(r.rows[1], "event.title")) == "1:1 w/ CEO";
  assert textOf(cell(r.rows[2], "event.title")) == "Carol sync";
});
