/// Differential oracle for `addIndex`/`addComposite` + the resumable chunked
/// backfill (`Backfill.step`) — issue #49. Ground truths:
///
///   • a backfilled index must equal an index BUILT BY WRITES over the same
///     rows, on every candidate shape (exact streams, ties included) —
///     backfill changes how an index comes to exist, never what it answers;
///   • while the walk is in flight the decl is PENDING: `kindOf`/
///     `compositeOf` are null (pinned directly), the candidate accessors
///     yield nothing, and the executor scans — proven with the ghost trick
///     (the served capability wired over an EMPTY scan source answers 0 rows
///     mid-walk, then answers from the index on the SAME registry the moment
///     the walk completes), so a partial store can never under-fetch
///     (issue #45);
///   • live writes DURING the walk — behind, at, and ahead of the cursor,
///     deletes included — converge with it (`onChange` + idempotent per-row
///     indexing), so the completed index equals a write-built one over the
///     final contents;
///   • many small steps == one big step (resumability), the iterator never
///     held across calls.

import { test } "mo:test";
import Array      "mo:core/Array";
import Iter       "mo:core/Iter";
import List       "mo:core/List";
import Nat        "mo:core/Nat";
import Option     "mo:core/Option";
import Backfill   "../src/Backfill";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _BoolValue "../src/BoolValue";
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Predicate  "../src/Predicate";
import Registry   "../src/Registry";
import SecondaryIndex "../src/SecondaryIndex";

type Rec = { id : Nat; kind : Text; amount : Nat };

func mk(k : Nat) : Rec = {
  id = k;
  kind = if (k % 3 == 0) "burn" else if (k % 3 == 1) "mint" else "xfer";
  amount = (k * 7) % 50;   // ties across ids
};

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

// Exact id SEQUENCE of a candidate stream (order matters: key order, ref
// order within a posting — two indexes over the same rows must agree).
func ids(it : { next : () -> ?(Nat, Rec) }) : [Nat] {
  let acc = List.empty<Nat>();
  for ((k, _) in it) { acc.add(k) };
  acc.toArray()
};

func same(a : [Nat], b : [Nat]) : Bool = Array.equal(a, b, Nat.equal);

type M = IndexedMap.IndexedMap<Nat, Rec>;

// The backfilled and the write-built index must answer every single-column
// shape with IDENTICAL streams.
func agreeSingle(filled : M, oracle : M) {
  for (k in ["burn", "mint", "xfer", "nope"].values()) {
    assert same(ids(filled.candidatesEq("kind", #text(k))), ids(oracle.candidatesEq("kind", #text(k))));
  };
  assert same(ids(filled.candidatesIn("kind", [#text("burn"), #text("mint")])),
              ids(oracle.candidatesIn("kind", [#text("burn"), #text("mint")])));
  assert same(ids(filled.candidatesRange("amount", null, null, #asc)),
              ids(oracle.candidatesRange("amount", null, null, #asc)));
  assert same(ids(filled.candidatesRange("amount", null, null, #desc)),
              ids(oracle.candidatesRange("amount", null, null, #desc)));
  assert same(ids(filled.candidatesRange("amount", ?#nat(10), ?#nat(35), #asc)),
              ids(oracle.candidatesRange("amount", ?#nat(10), ?#nat(35), #asc)));
  assert same(ids(filled.candidatesEq("amount", #nat(14))), ids(oracle.candidatesEq("amount", #nat(14))));
};

// ── (a) backfill over existing rows == an index built by writes ────────────

test("chunked backfill over a populated map == an index built by writes from empty", func () {
  let oracle = IndexedMap.new<Nat, Rec>([("kind", #hash), ("amount", #ordered)]);
  let filled = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 40) { oracle.put(k, mk(k)); filled.put(k, mk(k)); k += 1 };

  let stKind = filled.addIndex("kind", #hash);
  let stAmt  = filled.addIndex("amount", #ordered);
  var steps = 0;
  while (not Backfill.step(filled, stKind, 7)) { steps += 1; assert steps < 20 };
  while (not Backfill.step(filled, stAmt, 7))  { steps += 1; assert steps < 40 };
  assert stKind.done and stAmt.done;

  assert SecondaryIndex.kindOf(filled.ix, "kind")   == ?#hash;
  assert SecondaryIndex.kindOf(filled.ix, "amount") == ?#ordered;
  agreeSingle(filled, oracle);
});

// ── (b) readiness: pending never serves, and the flip is atomic ────────────

// The ghost trick (as in CompositeIndex.test.mo): `m`'s live served
// capability — the exact wiring `IndexedMap.entity` attaches — over an
// entity whose scan source is EMPTY. Whatever this registry answers came
// from the index; whatever the planner refuses to route answers empty.
func ghostServed(m : M) : (Rec -> Predicate.Row) -> Entity.Served =
  func (toPredRow : Rec -> Predicate.Row) : Entity.Served {
    func rows(refs : Iter.Iter<Nat>) : Iter.Iter<Predicate.Row> =
      refs.filterMap(func (k : Nat) : ?Predicate.Row =
        Option.map<Rec, Predicate.Row>(m.get(k), toPredRow));
    {
      prune  = null;
      kindOf = func (col : Text) : ?SecondaryIndex.Kind = SecondaryIndex.kindOf(m.ix, col);
      point  = func (col : Text, key : OQL.Value) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.point(m.ix, col, key));
      points = func (col : Text, keys : [OQL.Value]) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.points(m.ix, col, keys));
      range  = func (col : Text, lo : ?OQL.Value, hi : ?OQL.Value, dir : Entity.Dir) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.range(m.ix, col, lo, hi, dir));
      composites = ?{
        decls = func () : [[Text]] = SecondaryIndex.readyComposites(m.ix);
        range = func (cols : [Text], prefixEqs : [OQL.Value], lo : ?OQL.Value, hi : ?OQL.Value, dir : Entity.Dir) : Iter.Iter<Predicate.Row> =
          rows(SecondaryIndex.compositeRange(m.ix, cols, prefixEqs, lo, hi, dir));
      };
      stats = null;
    }
  };

func ghostRegOf(m : M) : Registry.Registry = Registry.build([
  Entity.new<Rec>("rec", func () = ([] : [Rec]).values(), "Rec", "id")
    .sample({ id = 0; kind = "burn"; amount = 0 })
    .withServed(ghostServed(m))
    .build()
]);

func q(where_ : ?Predicate.Predicate, orderBy : [Query.OrderBy], limit : ?Nat) : Query.Query = {
  start = "rec"; where_; groupBy = []; aggregate = [];
  orderBy; offset = null; limit; select = null;
};

func rowCount(reg : Registry.Registry, qq : Query.Query) : Nat =
  Executor.runWith(reg, qq, unrestricted).rows.size();

test("a pending column never serves: kindOf null, accessors empty, executor scans", func () {
  let m = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 30) { m.put(k, mk(k)); k += 1 };

  // Registries built BEFORE addIndex — the readiness flip must reach them live.
  let servedReg = Registry.build([ m.entity("rec", "Rec", "id").build() ]);
  let scanReg   = Registry.build([ Entity.new<Rec>("rec", func () = m.values(), "Rec", "id").build() ]);
  let ghostReg  = ghostRegOf(m);

  let st = m.addIndex("amount", #ordered);
  assert SecondaryIndex.kindOf(m.ix, "amount") == null;        // pending from the first moment
  assert not Backfill.step(m, st, 10);                          // 10 of 30 walked
  assert SecondaryIndex.kindOf(m.ix, "amount") == null;        // pinned: mid-walk the served path sees NO index

  // candidate accessors: pending reads exactly like unindexed (never partial)
  assert same(ids(m.candidatesRange("amount", null, null, #asc)), []);
  assert same(ids(m.candidatesEq("amount", #nat(mk(3).amount))), []);

  // the executor scans — results correct mid-walk (scan registry as truth) …
  let ge10 = q(?(#ge(["amount"], #nat(10))), [], null);
  let ord  = q(null, [{ field = ["amount"]; dir = #asc }], null);
  assert rowCount(servedReg, ge10) == rowCount(scanReg, ge10);
  assert rowCount(servedReg, ord)  == rowCount(scanReg, ord);
  // … and the ghost proves the index is NOT consulted: empty scan, 0 rows
  assert rowCount(ghostReg, ge10) == 0;
  assert rowCount(ghostReg, ord)  == 0;

  // complete the walk: the SAME registries flip to index-served
  while (not Backfill.step(m, st, 10)) {};
  assert SecondaryIndex.kindOf(m.ix, "amount") == ?#ordered;
  assert rowCount(ghostReg, ge10) == rowCount(scanReg, ge10);   // now answered from the index alone
  assert rowCount(ghostReg, ord)  == 30;
  assert rowCount(servedReg, ge10) == rowCount(scanReg, ge10);
  assert Backfill.step(m, st, 10);                              // stepping a done walk is a true no-op
});

// ── (c) live writes during the walk ────────────────────────────────────────

test("writes landing during the walk — behind, at, and ahead of the cursor — all converge", func () {
  let m = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 30) { m.put(k * 2, mk(k * 2)); k += 1 };   // even keys 0..58: room to insert behind

  let st = m.addIndex("amount", #ordered);
  assert not Backfill.step(m, st, 10);
  assert st.cursor == ?18;                               // keys 0,2,…,18 walked

  m.put(5,  { id = 5;  kind = "mint"; amount = 7 });     // INSERT behind the cursor
  m.put(4,  { mk(4)  with amount = 49 });                // UPDATE a walked row (posting must move)
  m.put(18, { mk(18) with amount = 1 });                 // UPDATE the cursor row itself
  m.put(19, { id = 19; kind = "xfer"; amount = 44 });    // INSERT just ahead
  m.put(40, { mk(40) with amount = 0 });                 // UPDATE an unwalked row (onChange now, walk later — dedup)

  assert not Backfill.step(m, st, 10);
  m.put(3, { id = 3; kind = "burn"; amount = 23 });      // behind, later in the walk
  while (not Backfill.step(m, st, 10)) {};

  // oracle: an index built by writes over the FINAL contents
  let oracle = IndexedMap.new<Nat, Rec>([("amount", #ordered)]);
  for ((key, v) in m.entries()) { oracle.put(key, v) };
  assert same(ids(m.candidatesRange("amount", null, null, #asc)),
              ids(oracle.candidatesRange("amount", null, null, #asc)));
  assert same(ids(m.candidatesRange("amount", null, null, #desc)),
              ids(oracle.candidatesRange("amount", null, null, #desc)));
  for (a in [49, 1, 44, 0, 23, 7].values()) {
    assert same(ids(m.candidatesEq("amount", #nat(a))), ids(oracle.candidatesEq("amount", #nat(a))));
  };
  assert ids(m.candidatesRange("amount", null, null, #asc)).size() == m.size();  // every row, exactly once
});

// ── (d) deletes during the walk ────────────────────────────────────────────

test("deletes during the walk — a walked row, an unwalked row, and the cursor row", func () {
  let m = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 30) { m.put(k * 2, mk(k * 2)); k += 1 };

  let st = m.addIndex("amount", #ordered);
  assert not Backfill.step(m, st, 10);
  assert st.cursor == ?18;

  m.delete(4);    // walked: onChange must drop its posting
  m.delete(50);   // unwalked: never indexed, never walked
  m.delete(18);   // the CURSOR row: the next step must land on 20 and carry on
  while (not Backfill.step(m, st, 10)) {};

  let oracle = IndexedMap.new<Nat, Rec>([("amount", #ordered)]);
  for ((key, v) in m.entries()) { oracle.put(key, v) };
  let stream = ids(m.candidatesRange("amount", null, null, #asc));
  assert same(stream, ids(oracle.candidatesRange("amount", null, null, #asc)));
  assert stream.size() == 27;
  for (gone in [4, 50, 18].values()) {
    assert not stream.values().any(func (i : Nat) : Bool = i == gone);
  };
});

// ── (e) resumability: many small steps == one big step ─────────────────────

test("budget-1 resume across many steps == one unbounded step", func () {
  let small = IndexedMap.new<Nat, Rec>([]);
  let big   = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 25) { small.put(k, mk(k)); big.put(k, mk(k)); k += 1 };

  let stS = small.addIndex("amount", #ordered);
  var steps = 1;
  while (not Backfill.step(small, stS, 1)) { steps += 1; assert steps <= 25 };
  assert steps == 25;                                    // one row per step, no re-walk of the cursor

  let stB = big.addIndex("amount", #ordered);
  assert Backfill.step(big, stB, 1_000_000);             // the whole table in one call

  assert same(ids(small.candidatesRange("amount", null, null, #asc)),
              ids(big.candidatesRange("amount", null, null, #asc)));
  assert same(ids(small.candidatesRange("amount", null, null, #desc)),
              ids(big.candidatesRange("amount", null, null, #desc)));
});

test("addIndex on an empty map is ready after one step (and writes then index live)", func () {
  let m = IndexedMap.new<Nat, Rec>([]);
  let st = m.addIndex("amount", #ordered);
  assert SecondaryIndex.kindOf(m.ix, "amount") == null;
  assert Backfill.step(m, st, 1);
  assert SecondaryIndex.kindOf(m.ix, "amount") == ?#ordered;
  m.put(1, mk(1));
  assert same(ids(m.candidatesEq("amount", #nat(mk(1).amount))), [1]);
});

// ── (f) composite backfill ─────────────────────────────────────────────────

test("composite backfill: pending never routes, completion equals a write-built composite", func () {
  let cols = ["kind", "amount"];
  let m = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 40) { m.put(k, mk(k)); k += 1 };
  let ghostReg = ghostRegOf(m);

  let st = m.addComposite(cols, #ordered);
  assert not Backfill.step(m, st, 15);

  // mid-walk: undeclared to every reader
  assert SecondaryIndex.compositeOf(m.ix, cols) == null;
  assert SecondaryIndex.readyComposites(m.ix).size() == 0;
  assert same(ids(m.candidatesComposite(cols, [#text("burn")], null, null, #asc)), []);
  let prefix  = q(?(#eq(["kind"], #text("burn"))), [], null);
  let prefOrd = q(?(#eq(["kind"], #text("burn"))), [{ field = ["amount"]; dir = #desc }], null);
  assert rowCount(ghostReg, prefix)  == 0;               // no composite route, scan (empty) serves
  assert rowCount(ghostReg, prefOrd) == 0;

  m.put(100, { id = 100; kind = "burn"; amount = 49 });  // live write ahead of the walk
  while (not Backfill.step(m, st, 15)) {};

  assert SecondaryIndex.compositeOf(m.ix, cols) == ?#ordered;
  assert SecondaryIndex.readyComposites(m.ix) == [cols];

  // oracle: the same rows behind a constructor-declared composite
  let oracle = IndexedMap.newWith<Nat, Rec>([], [(cols, #ordered)]);
  for ((key, v) in m.entries()) { oracle.put(key, v) };
  assert same(ids(m.candidatesComposite(cols, [], null, null, #asc)),
              ids(oracle.candidatesComposite(cols, [], null, null, #asc)));
  assert same(ids(m.candidatesComposite(cols, [], null, null, #desc)),
              ids(oracle.candidatesComposite(cols, [], null, null, #desc)));
  assert same(ids(m.candidatesComposite(cols, [#text("burn")], ?#nat(10), ?#nat(49), #asc)),
              ids(oracle.candidatesComposite(cols, [#text("burn")], ?#nat(10), ?#nat(49), #asc)));
  assert same(ids(m.candidatesComposite(cols, [#text("burn"), #nat(49)], null, null, #asc)),
              ids(oracle.candidatesComposite(cols, [#text("burn"), #nat(49)], null, null, #asc)));

  // the SAME ghost registry now routes the prefix shapes through the index
  assert rowCount(ghostReg, prefix)  == 15;              // 14 burns of 0..39, +1 live-written
  assert rowCount(ghostReg, prefOrd) == 15;
});
