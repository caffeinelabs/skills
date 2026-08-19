/// Adversarial probes for the composite-index + backfill work (issue #49) —
/// each test targets a specific way the implementation COULD have been wrong:
///
///   • `compareSeq` under MIXED numeric encodings: a `#nat`/`#int`/`#float`
///     prefix must land in one equivalence class (the exact `cmpFloatInt`
///     bridge), including at/past 2^53 where the old lossy bridge broke
///     transitivity (issue #45) — now in composite key VECTORS;
///   • seek/`takeWhile` boundaries: a probe for prefix `[A]` must never leak
///     into an adjacent prefix (`#nat 9` vs `#nat 10`, `"a"` vs `"ab"`) and a
///     descending probe must be exact at the far edges;
///   • the executor's composite `orderBy` route when the composite carries
///     TRAILING columns beyond the ordered one (tie order is composite-key
///     order — SQL-legal, pinned here so a change is loud);
///   • fallback when only SOME shapes match (single-column routes coexist
///     with composite decls);
///   • backfill chunk boundaries under churn: the cursor row deleted AND
///     re-inserted with a different value between steps, inserts just before/
///     after the cursor, exact-budget completion (no phantom extra step).

import { test } "mo:test";
import Array      "mo:core/Array";
import Iter       "mo:core/Iter";
import List       "mo:core/List";
import Nat        "mo:core/Nat";
import Option     "mo:core/Option";
import Order      "mo:core/Order";
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

type Value = OQL.Value;

let two53 : Nat = 9_007_199_254_740_992;   // 2^53

func collect(it : Iter.Iter<Nat>) : [Nat] {
  let acc = List.empty<Nat>();
  for (r in it) { acc.add(r) };
  acc.toArray()
};

func same(a : [Nat], b : [Nat]) : Bool = Array.equal(a, b, Nat.equal);

// A raw two-column composite store over hand-built rows, so the key VECTORS
// can carry any Value encoding (the derived `_toRow` of a record type never
// mixes encodings in one column).
func rawAB() : SecondaryIndex.Index<Nat> =
  SecondaryIndex.emptyWith<Nat>([], [(["a", "b"], #ordered)]);

func putAB(ix : SecondaryIndex.Index<Nat>, ref : Nat, a : Value, b : Value) =
  SecondaryIndex.onChange<Nat>(ix, Nat.compare, ref, null, ?[("a", a), ("b", b)]);

func probe(ix : SecondaryIndex.Index<Nat>, prefix : [Value], lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : [Nat] =
  collect(SecondaryIndex.compositeRange<Nat>(ix, ["a", "b"], prefix, lo, hi, dir));

// ── compareSeq: mixed encodings are one equivalence class ──────────────────

test("compareSeq bridges #nat/#int/#float element-wise, shorter before extension", func () {
  assert SecondaryIndex.compareSeq([#nat(5)], [#int(5)]) == #equal;
  assert SecondaryIndex.compareSeq([#float(5.0), #text("x")], [#nat(5), #text("x")]) == #equal;
  assert SecondaryIndex.compareSeq([#nat(5)], [#nat(5), #nat(0)]) == #less;      // prefix < extension
  assert SecondaryIndex.compareSeq([#nat(5), #nat(0)], [#nat(5)]) == #greater;
  assert SecondaryIndex.compareSeq([#nat(9)], [#nat(10)]) == #less;              // numeric, not decimal-string
  // exactness at 2^53 survives inside a vector
  assert SecondaryIndex.compareSeq([#float(9007199254740992.0)], [#nat(two53)]) == #equal;
  assert SecondaryIndex.compareSeq([#float(9007199254740992.0)], [#nat(two53 + 1)]) == #less;
});

test("mixed-encoding prefixes collapse into one class, any-encoding probe finds all", func () {
  let ix = rawAB();
  putAB(ix, 1, #nat(5),     #nat(1));
  putAB(ix, 2, #int(5),     #nat(2));
  putAB(ix, 3, #float(5.0), #nat(3));
  putAB(ix, 4, #nat(4),     #nat(9));
  putAB(ix, 5, #int(6),     #nat(0));
  for (p in ([[#nat(5)], [#int(5)], [#float(5.0)]] : [[Value]]).values()) {
    assert same(probe(ix, p, null, null, #asc),  [1, 2, 3]);   // b asc
    assert same(probe(ix, p, null, null, #desc), [3, 2, 1]);
  };
  // mixed-encoding BOUNDS on the next column
  assert same(probe(ix, [#nat(5)], ?#int(2), null, #asc), [2, 3]);
  assert same(probe(ix, [#nat(5)], null, ?#float(2.5), #asc), [1, 2]);
});

test("float probe of a composite PREFIX is exact at 2^53 (issue #45 class)", func () {
  let ix = rawAB();
  putAB(ix, 1, #nat(two53),     #nat(1));
  putAB(ix, 2, #nat(two53 + 1), #nat(1));
  putAB(ix, 3, #int(two53),     #nat(2));
  // float 2^53 pins EXACTLY the 2^53 class — never its neighbour
  assert same(probe(ix, [#float(9007199254740992.0)], null, null, #asc),  [1, 3]);
  assert same(probe(ix, [#float(9007199254740992.0)], null, null, #desc), [3, 1]);
  assert same(probe(ix, [#nat(two53 + 1)], null, null, #asc), [2]);
});

test("float bound on the NEXT column is exact at 2^53", func () {
  let ix = rawAB();
  putAB(ix, 1, #text("x"), #nat(two53));
  putAB(ix, 2, #text("x"), #nat(two53 + 1));
  let f : Value = #float(9007199254740992.0);
  assert same(probe(ix, [#text("x")], ?f, ?f, #asc), [1]);        // [2^53, 2^53] exactly
  assert same(probe(ix, [#text("x")], ?f, null, #asc), [1, 2]);   // ge is still a superset upward
  assert same(probe(ix, [#text("x")], null, ?f, #desc), [1]);
});

// ── seek/takeWhile boundaries: no leak into adjacent prefixes ──────────────

test("numeric prefix adjacency: [9] never leaks into [10] or [90]", func () {
  let ix = rawAB();
  putAB(ix, 1, #nat(9),  #nat(0));
  putAB(ix, 2, #nat(10), #nat(0));
  putAB(ix, 3, #nat(90), #nat(0));
  assert same(probe(ix, [#nat(9)], null, null, #asc),  [1]);
  assert same(probe(ix, [#nat(9)], null, null, #desc), [1]);
  assert same(probe(ix, [], ?#nat(10), null, #asc), [2, 3]);      // empty prefix + bound on col a
});

test("text prefix adjacency: 'a' picks exactly 'a', not its textual extensions", func () {
  let ix = rawAB();
  putAB(ix, 1, #text("a"),        #nat(0));
  putAB(ix, 2, #text("a "),       #nat(0));
  putAB(ix, 3, #text("a\u{1f}b"), #nat(0));
  putAB(ix, 4, #text("ab"),       #nat(0));
  putAB(ix, 5, #text("b"),        #nat(0));
  assert same(probe(ix, [#text("a")], null, null, #asc),  [1]);
  assert same(probe(ix, [#text("a")], null, null, #desc), [1]);
  assert same(probe(ix, [#text("aa")], null, null, #asc), []);    // between stored prefixes
  assert same(probe(ix, [#text("")],  null, null, #asc), []);     // below every prefix
  assert same(probe(ix, [#text("zz")], null, null, #desc), []);   // above every prefix
});

test("descending probes are exact at the far edges of the next column", func () {
  let ix = rawAB();
  putAB(ix, 1, #text("k"), #nat(10));
  putAB(ix, 2, #text("k"), #nat(20));
  putAB(ix, 3, #text("k"), #nat(30));
  putAB(ix, 9, #text("j"), #nat(99));   // adjacent prefix BELOW — a desc seek must not slide into it
  assert same(probe(ix, [#text("k")], null, ?#nat(5),   #desc), []);
  assert same(probe(ix, [#text("k")], null, ?#nat(10),  #desc), [1]);
  assert same(probe(ix, [#text("k")], null, ?#nat(25),  #desc), [2, 1]);
  assert same(probe(ix, [#text("k")], null, ?#nat(100), #desc), [3, 2, 1]);
  assert same(probe(ix, [#text("k")], ?#nat(25), null,  #desc), [3]);
  assert same(probe(ix, [#text("k")], ?#nat(35), null,  #asc),  []);
  // a full-length prefix ignores bounds by contract
  assert same(collect(SecondaryIndex.compositeRange<Nat>(ix, ["a", "b"], [#text("k"), #nat(20)], ?#nat(0), ?#nat(0), #desc)), [2]);
});

// ── executor: orderBy on a MIDDLE composite column (trailing columns) ──────

type Emp = { id : Nat; dept : Text; role : Text; salary : Nat };

let staff : [Emp] = [
  { id = 1; dept = "eng"; role = "dev"; salary = 50 },
  { id = 2; dept = "eng"; role = "dev"; salary = 60 },
  { id = 3; dept = "eng"; role = "ops"; salary = 60 },
  { id = 4; dept = "eng"; role = "dev"; salary = 70 },
  { id = 5; dept = "eng"; role = "qa";  salary = 80 },
  { id = 6; dept = "eng"; role = "dev"; salary = 60 },
  { id = 7; dept = "ops"; role = "dev"; salary = 40 },
];

let emps3 = IndexedMap.newWith<Nat, Emp>([], [(["dept", "role", "salary"], #ordered)]);
for (e in staff.values()) { emps3.put(e.id, e) };

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;
let servedReg3 = Registry.build([ emps3.entity("emp", "Emp", "id").build() ]);
let scanReg3   = Registry.build([ Entity.new<Emp>("emp", func () = emps3.values(), "Emp", "id").build() ]);

func q(where_ : ?Predicate.Predicate, orderBy : [Query.OrderBy], limit : ?Nat) : Query.Query = {
  start = "emp"; where_; groupBy = []; aggregate = [];
  orderBy; offset = null; limit; select = null;
};

func cell(row : [Executor.Cell], name : Text) : ?Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

func resultIds(reg : Registry.Registry, qq : Query.Query) : [Nat] {
  let acc = List.empty<Nat>();
  for (r in Executor.runWith(reg, qq, unrestricted).rows.values()) {
    switch (cell(r, "id")) { case (?#nat(i)) { acc.add(i) }; case _ { assert false } };
  };
  acc.toArray()
};

test("orderBy the 2nd of 3 composite columns: ordered + exact multiset; ties in composite-key order", func () {
  let ord : [Query.OrderBy] = [{ field = ["role"]; dir = #asc }];
  let qq = q(?(#eq(["dept"], #text("eng"))), ord, null);
  let served = resultIds(servedReg3, qq);
  let scan   = resultIds(scanReg3, qq);
  // same matches, both correctly ordered by role
  assert same(Array.sort(served, Nat.compare), Array.sort(scan, Nat.compare));
  assert served.size() == 6;
  // The composite route streams key order (role, then SALARY, then id), so the
  // dev tie comes salary-ordered; the scan sorts stable, so its tie keeps id
  // order. Both satisfy `orderBy role` — tie order under a single-key orderBy
  // is unspecified (SQL semantics, Executor.planServed doc). Pinned so a
  // silent change in either path is loud:
  assert same(served, [1, 2, 6, 4, 3, 5]);
  assert same(scan,   [1, 2, 4, 6, 3, 5]);
  // desc mirrors the key order; still correctly ordered, still the same set
  let dq = q(?(#eq(["dept"], #text("eng"))), [{ field = ["role"]; dir = #desc }], null);
  assert same(resultIds(servedReg3, dq), [5, 3, 4, 2, 6, 1]);
  // top-N through the ordered route crosses the tie without a sort
  assert same(resultIds(servedReg3, q(?(#eq(["dept"], #text("eng"))), ord, ?2)), [1, 2]);
});

// ── executor: only SOME shapes match → the right route, never a wrong one ──

let emps = IndexedMap.newWith<Nat, Emp>([("role", #hash)], [(["dept", "salary"], #ordered)]);
for (e in staff.values()) { emps.put(e.id, e) };
let servedReg = Registry.build([ emps.entity("emp", "Emp", "id").build() ]);
let scanReg   = Registry.build([ Entity.new<Emp>("emp", func () = emps.values(), "Emp", "id").build() ]);

func agreeUnbounded(qq : Query.Query) {
  assert same(Array.sort(resultIds(servedReg, qq), Nat.compare),
              Array.sort(resultIds(scanReg,   qq), Nat.compare));
};

test("partial shape matches fall to the narrowest legal route, results = scan", func () {
  // no dept ⇒ no composite prefix ⇒ single-column role probe + residual
  agreeUnbounded(q(?(#and_([#eq(["role"], #text("dev")), #ge(["salary"], #nat(60))])), [], null));
  // bare composite prefix AND a single-column eq: either route is legal
  agreeUnbounded(q(?(#and_([#eq(["dept"], #text("eng")), #eq(["role"], #text("dev"))])), [], null));
  // range on the 2nd composite column alone ⇒ scan
  agreeUnbounded(q(?(#ge(["salary"], #nat(60))), [], null));
  // composite prefix + range + an extra unindexed residual conjunct
  agreeUnbounded(q(?(#and_([#eq(["dept"], #text("eng")), #ge(["salary"], #nat(55)), #eq(["id"], #nat(4))])), [], null));
});

// ── backfill: cursor churn at chunk boundaries ─────────────────────────────

type Rec = { id : Nat; kind : Text; amount : Nat };

func mk(k : Nat) : Rec = {
  id = k;
  kind = if (k % 3 == 0) "burn" else if (k % 3 == 1) "mint" else "xfer";
  amount = (k * 7) % 50;
};

func ids(it : { next : () -> ?(Nat, Rec) }) : [Nat] {
  let acc = List.empty<Nat>();
  for ((k, _) in it) { acc.add(k) };
  acc.toArray()
};

test("cursor deleted AND re-inserted with a new value between steps; inserts hugging the cursor", func () {
  let cols = ["kind", "amount"];
  let m = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 30) { m.put(k * 2, mk(k * 2)); k += 1 };            // even keys 0..58

  let st = m.addComposite(cols, #ordered);
  assert not Backfill.step(m, st, 10);
  assert st.cursor == ?18;

  m.delete(18);                                                   // cursor row gone …
  m.put(18, { id = 18; kind = "mint"; amount = 3 });              // … and back with a DIFFERENT key vector
  m.put(19, { id = 19; kind = "burn"; amount = 44 });             // insert just AFTER the cursor
  m.put(17, { id = 17; kind = "xfer"; amount = 9 });              // insert just BEFORE it (behind)

  assert not Backfill.step(m, st, 10);
  while (not Backfill.step(m, st, 7)) {};

  let oracle = IndexedMap.newWith<Nat, Rec>([], [(cols, #ordered)]);
  for ((key, v) in m.entries()) { oracle.put(key, v) };
  assert same(ids(m.candidatesComposite(cols, [], null, null, #asc)),
              ids(oracle.candidatesComposite(cols, [], null, null, #asc)));
  assert same(ids(m.candidatesComposite(cols, [], null, null, #desc)),
              ids(oracle.candidatesComposite(cols, [], null, null, #desc)));
  assert same(ids(m.candidatesComposite(cols, [#text("mint")], ?#nat(3), ?#nat(3), #asc)),
              ids(oracle.candidatesComposite(cols, [#text("mint")], ?#nat(3), ?#nat(3), #asc)));
  assert ids(m.candidatesComposite(cols, [], null, null, #asc)).size() == m.size();  // once each, none lost
});

test("exact-budget steps: the walk completes without a phantom extra call", func () {
  // budget == remaining rows on the LAST chunk: done flips in that same call
  let a = IndexedMap.new<Nat, Rec>([]);
  var k = 0;
  while (k < 30) { a.put(k, mk(k)); k += 1 };
  let stA = a.addIndex("amount", #ordered);
  assert not Backfill.step(a, stA, 10);                           // rows 0..9
  assert not Backfill.step(a, stA, 10);                           // rows 10..19
  assert Backfill.step(a, stA, 10);                               // rows 20..29 — exhausts exactly
  assert SecondaryIndex.kindOf(a.ix, "amount") == ?#ordered;

  // budget == the whole table in ONE first call
  let b = IndexedMap.new<Nat, Rec>([]);
  k := 0;
  while (k < 25) { b.put(k, mk(k)); k += 1 };
  let stB = b.addIndex("amount", #ordered);
  assert Backfill.step(b, stB, 25);

  // both walks must equal a write-built index over the same rows
  let oracleA = IndexedMap.new<Nat, Rec>([("amount", #ordered)]);
  for ((key, v) in a.entries()) { oracleA.put(key, v) };
  assert same(ids(a.candidatesRange("amount", null, null, #asc)),
              ids(oracleA.candidatesRange("amount", null, null, #asc)));
  let oracleB = IndexedMap.new<Nat, Rec>([("amount", #ordered)]);
  for ((key, v) in b.entries()) { oracleB.put(key, v) };
  assert same(ids(b.candidatesRange("amount", null, null, #asc)),
              ids(oracleB.candidatesRange("amount", null, null, #asc)));
});

// ── two composites: one ready, one pending — gates stay independent ────────

func ghostServed(m : IndexedMap.IndexedMap<Nat, Rec>) : (Rec -> Predicate.Row) -> Entity.Served =
  func (toPredRow : Rec -> Predicate.Row) : Entity.Served {
    func rows(refs : Iter.Iter<Nat>) : Iter.Iter<Predicate.Row> =
      refs.filterMap(func (k : Nat) : ?Predicate.Row =
        Option.map<Rec, Predicate.Row>(m.get(k), toPredRow));
    {
      prune  = null;
      kindOf = func (col : Text) : ?SecondaryIndex.Kind = SecondaryIndex.kindOf(m.ix, col);
      point  = func (col : Text, key : Value) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.point(m.ix, col, key));
      points = func (col : Text, keys : [Value]) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.points(m.ix, col, keys));
      range  = func (col : Text, lo : ?Value, hi : ?Value, dir : Entity.Dir) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.range(m.ix, col, lo, hi, dir));
      composites = ?{
        decls = func () : [[Text]] = SecondaryIndex.readyComposites(m.ix);
        range = func (cols : [Text], prefixEqs : [Value], lo : ?Value, hi : ?Value, dir : Entity.Dir) : Iter.Iter<Predicate.Row> =
          rows(SecondaryIndex.compositeRange(m.ix, cols, prefixEqs, lo, hi, dir));
      };
      stats = null;
    }
  };

test("a pending composite never routes while a ready sibling still serves", func () {
  let ready   = ["kind", "amount"];
  let pending = ["amount", "kind"];
  let m = IndexedMap.newWith<Nat, Rec>([], [(ready, #ordered)]);
  var k = 0;
  while (k < 40) { m.put(k, mk(k)); k += 1 };
  let ghostReg = Registry.build([
    Entity.new<Rec>("rec", func () = ([] : [Rec]).values(), "Rec", "id")
      .sample({ id = 0; kind = "burn"; amount = 0 })
      .withServed(ghostServed(m))
      .build()
  ]);
  func ghost(qq : Query.Query) : Nat = Executor.runWith(ghostReg, { qq with start = "rec" }, unrestricted).rows.size();

  let st = m.addComposite(pending, #ordered);
  assert not Backfill.step(m, st, 15);
  assert SecondaryIndex.readyComposites(m.ix) == [ready];

  let burnQ   = q(?(#eq(["kind"], #text("burn"))), [], null);                       // ready prefix
  let amountQ = q(?(#eq(["amount"], #nat(7))), [], null);                           // PENDING prefix
  assert ghost(burnQ) == 14;                                     // burns of 0..39 — ready composite serves
  assert ghost(amountQ) == 0;                                    // pending: scan (empty) — half-built store never consulted

  while (not Backfill.step(m, st, 15)) {};
  assert SecondaryIndex.readyComposites(m.ix).size() == 2;
  var expect = 0;
  for ((_, r) in m.entries()) { if (r.amount == 7) expect += 1 };
  assert ghost(amountQ) == expect;                               // the flip: same registry now serves it
});
