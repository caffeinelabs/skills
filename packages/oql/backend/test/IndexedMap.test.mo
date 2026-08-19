/// Differential oracle for `IndexedMap`: the maintained index must change the
/// access path, never the answer. For each query shape we compute the matching
/// row-id set two ways — a full SCAN filtered by the predicate, and the INDEX
/// candidates (a superset) filtered by the SAME predicate — and assert they
/// agree. We re-run the whole battery after inserts, an update that MOVES a
/// row's indexed keys, an update of a NON-indexed field (the key-unchanged skip
/// path), and a delete — so stale/duplicate/missing postings all surface as a
/// disagreement with the scan.

import { test } "mo:test";
import Array    "mo:core/Array";
import List     "mo:core/List";
import Nat      "mo:core/Nat";
import Order    "mo:core/Order";
import IndexedMap "../src/IndexedMap";
import OQL      "../src";
import _NatValue    "../src/NatValue";
import _TextValue   "../src/TextValue";
import _RecordValue "../src/RecordValue";

type Rec = { id : Nat; kind : Text; amount : Nat; note : Text };

func mk(k : Nat) : Rec = {
  id = k;
  kind = if (k % 3 == 0) "burn" else if (k % 3 == 1) "mint" else "xfer";
  amount = (k * 5) % 60;   // ties on amount across ids
  note = "n" # Nat.toText(k);
};

// A fresh 20-row map indexed on kind (#hash) and amount (#ordered), populated
// entirely through `put` (so the index is built by the writes, no backfill).
// `m.put(k, v)` derives BOTH implicits — `compare` (Nat) and `_toRow` (the
// __record combiner over Rec) — so no explicit args.
func fresh() : IndexedMap.IndexedMap<Nat, Rec> {
  let m = IndexedMap.new<Nat, Rec>([("kind", #hash), ("amount", #ordered)]);
  var k = 0;
  while (k < 20) { m.put(k, mk(k)); k += 1 };
  m
};

// ids matching `pred`, sorted — for SET comparison (unordered shapes).
func idsSorted(it : { next : () -> ?(Nat, Rec) }, pred : Rec -> Bool) : [Nat] {
  let acc = List.empty<Nat>();
  for ((k, r) in it) { if (pred(r)) acc.add(k) };
  Array.sort(acc.toArray(), Nat.compare)
};

func eq(a : [Nat], b : [Nat]) : Bool = Array.equal(a, b, Nat.equal);

// Assert scan and index agree on the id SET for one shape.
func agree(
  m         : IndexedMap.IndexedMap<Nat, Rec>,
  pred      : Rec -> Bool,
  candidates : { next : () -> ?(Nat, Rec) },
) {
  let scan  = idsSorted(m.entries(), pred);
  let index = idsSorted(candidates, pred);
  assert eq(scan, index);
};

// The four shapes we check after every mutation.
func battery(m : IndexedMap.IndexedMap<Nat, Rec>) {
  // #eq on a #hash column
  agree(m, func r = r.kind == "burn", m.candidatesEq("kind", #text("burn")));
  // #in_ on a #hash column
  agree(m, func r = r.kind == "burn" or r.kind == "mint",
        m.candidatesIn("kind", [#text("burn"), #text("mint")]));
  // range >= on an #ordered column (lower bound only)
  agree(m, func r = r.amount >= 30, m.candidatesRange("amount", ?#nat(30), null, #asc));
  // strict < via an inclusive superset + residual (boundary key dropped by the filter)
  agree(m, func r = r.amount < 30, m.candidatesRange("amount", null, ?#nat(30), #asc));
  // bounded range on an #ordered column
  agree(m, func r = r.amount >= 15 and r.amount <= 45,
        m.candidatesRange("amount", ?#nat(15), ?#nat(45), #asc));
};

test("index agrees with scan after inserts", func () {
  battery(fresh());
});

test("update that MOVES both indexed keys stays consistent", func () {
  let m = fresh();
  // id 3 was kind=burn, amount=15; move it to kind=mint, amount=999.
  m.put(3, { id = 3; kind = "mint"; amount = 999; note = "moved" });
  battery(m);
  // moved into the new buckets: a >=999 range finds exactly id 3 ...
  assert eq(idsSorted(m.candidatesRange("amount", ?#nat(999), null, #asc), func r = r.amount >= 999), [3]);
  // ... and out of the old one: id 3's old amount (15) no longer returns it
  assert eq(idsSorted(m.candidatesEq("amount", #nat(15)), func r = r.id == 3), []);
});

test("update of a NON-indexed field (key-unchanged skip) keeps the row indexed", func () {
  let m = fresh();
  let before = idsSorted(m.candidatesEq("kind", #text("burn")), func r = r.kind == "burn");
  m.put(9, { mk(9) with note = "touched" });   // 9 is kind=burn; only note changes
  battery(m);
  let after = idsSorted(m.candidatesEq("kind", #text("burn")), func r = r.kind == "burn");
  assert eq(before, after);   // the skip path must not drop the row
});

test("delete removes a row from every index", func () {
  let m = fresh();
  m.delete(6);    // 6 is kind=burn, amount=30
  battery(m);
  // 6 must be gone from the kind and amount indexes
  assert eq(idsSorted(m.candidatesEq("kind", #text("burn")), func r = r.id == 6), []);
  assert eq(idsSorted(m.candidatesRange("amount", ?#nat(30), ?#nat(30), #asc), func r = r.id == 6), []);
});

test("ordered range yields amount-asc, id-asc (matches a stable scan sort)", func () {
  let m = fresh();
  m.delete(6);
  m.put(3, { id = 3; kind = "mint"; amount = 999; note = "moved" });

  // expected: all rows, sorted by (amount asc, id asc)
  let all = List.empty<(Nat, Rec)>();
  for (kv in m.entries()) { all.add(kv) };
  let sorted = Array.sort<(Nat, Rec)>(all.toArray(), func ((k1, r1), (k2, r2)) : Order.Order =
    switch (Nat.compare(r1.amount, r2.amount)) { case (#equal) Nat.compare(k1, k2); case o o });
  let expected = List.empty<Nat>();
  for ((k, _) in sorted.values()) { expected.add(k) };

  // actual: the full ordered range, in the order the index yields it
  let actual = List.empty<Nat>();
  for ((k, _) in m.candidatesRange("amount", null, null, #asc)) { actual.add(k) };

  assert eq(actual.toArray(), expected.toArray());   // exact SEQUENCE, ties included
});

// ── shape edge cases ────────────────────────────────────────────────────────

test("#eq with no matching key returns empty", func () {
  let m = fresh();
  agree(m, func r = r.kind == "nope", m.candidatesEq("kind", #text("nope")));
  let ids = idsSorted(m.candidatesEq("kind", #text("nope")), func _ = true);
  assert eq(ids, []);
});

test("#in_ variants: empty array, all-absent keys, and present mix", func () {
  let m = fresh();
  // empty candidate set → nothing
  assert eq(idsSorted(m.candidatesIn("kind", []), func _ = true), []);
  // all-absent keys → nothing
  assert eq(idsSorted(m.candidatesIn("kind", [#text("nope"), #text("zzz")]), func _ = true), []);
  // present ∪ absent → just the present
  agree(m, func r = r.kind == "burn",
        m.candidatesIn("kind", [#text("burn"), #text("nope")]));
});

test("#in_ with duplicate / mixed-encoding keys surfaces each row once", func () {
  let m = fresh();
  // amount 30 exists (ids 6, 18: (6*5)%60=30, (18*5)%60=30). Query it three ways
  // that all `Predicate.compare`-equal — the union must not double-count.
  let got = idsSorted(m.candidatesIn("amount", [#nat(30), #int(30), #nat(30)]), func r = r.amount == 30);
  let want = idsSorted(m.entries(), func r = r.amount == 30);
  assert eq(got, want);
});

test("range boundaries: le vs lt, ge vs gt (inclusive superset + residual)", func () {
  let m = fresh();
  // <= 30 and < 30 share the same inclusive candidate stream; residual decides.
  agree(m, func r = r.amount <= 30, m.candidatesRange("amount", null, ?#nat(30), #asc));
  agree(m, func r = r.amount <  30, m.candidatesRange("amount", null, ?#nat(30), #asc));
  agree(m, func r = r.amount >= 30, m.candidatesRange("amount", ?#nat(30), null, #asc));
  agree(m, func r = r.amount >  30, m.candidatesRange("amount", ?#nat(30), null, #asc));
});

test("empty ranges above the max and below the min", func () {
  let m = fresh();
  assert eq(idsSorted(m.candidatesRange("amount", ?#nat(1000), null, #asc), func _ = true), []);
  assert eq(idsSorted(m.candidatesRange("amount", null, ?#nat(0), #asc), func r = r.amount < 0), []);
});

test("descending range yields amount-desc, id-asc within ties", func () {
  let m = fresh();
  // expected: all rows sorted by (amount desc, id asc) — a stable desc sort
  // keeps equal keys in input (id) order.
  let all = List.empty<(Nat, Rec)>();
  for (kv in m.entries()) { all.add(kv) };
  let sorted = Array.sort<(Nat, Rec)>(all.toArray(), func ((k1, r1), (k2, r2)) : Order.Order =
    switch (Nat.compare(r2.amount, r1.amount)) { case (#equal) Nat.compare(k1, k2); case o o });
  let expected = List.empty<Nat>();
  for ((k, _) in sorted.values()) { expected.add(k) };
  let actual = List.empty<Nat>();
  for ((k, _) in m.candidatesRange("amount", null, null, #desc)) { actual.add(k) };
  assert eq(actual.toArray(), expected.toArray());
});

test("#nat / #int query key bridges to a #nat-indexed column", func () {
  let m = fresh();
  // rows store amount as #nat; query with #int(30) must still find them.
  agree(m, func r = r.amount == 30, m.candidatesEq("amount", #int(30)));
});

test("all-equal key: one bucket returns every row", func () {
  let m = IndexedMap.new<Nat, Rec>([("amount", #ordered)]);
  var k = 0;
  while (k < 10) { m.put(k, { id = k; kind = "x"; amount = 5; note = "" }); k += 1 };
  // point at the single key → all ten, in id order
  let got = List.empty<Nat>();
  for ((id, _) in m.candidatesEq("amount", #nat(5))) { got.add(id) };
  assert eq(got.toArray(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
  // a range excluding 5 is empty
  assert eq(idsSorted(m.candidatesRange("amount", ?#nat(6), null, #asc), func r = r.amount >= 6), []);
});

// ── null / missing-key column ───────────────────────────────────────────────

type Opt = { id : Nat; tag : Text };   // tag "" is rendered as #null_
func optRow(o : Opt) : OQL.Entity.Row = [
  ("id", #nat(o.id)), ("tag", if (o.tag == "") #null_ else #text(o.tag)),
];
func optFresh() : IndexedMap.IndexedMap<Nat, Opt> {
  let m = IndexedMap.new<Nat, Opt>([("tag", #hash)]);
  var k = 0;
  // pass the custom optRow explicitly (it maps "" -> #null_; the derived row would not)
  while (k < 12) { m.put(k, { id = k; tag = if (k % 2 == 0) "" else "t" # Nat.toText(k % 3) }, Nat.compare, optRow); k += 1 };
  m
};

test("#null_ is a first-class key: missing values are found and move correctly", func () {
  let m = optFresh();
  // the even ids (tag "") index under #null_
  let nulls = List.empty<Nat>();
  for ((id, _) in m.candidatesEq("tag", #null_)) { nulls.add(id) };
  assert eq(Array.sort(nulls.toArray(), Nat.compare), [0, 2, 4, 6, 8, 10]);
  // give id 4 a real tag → it leaves the null bucket
  m.put(4, { id = 4; tag = "t1" }, Nat.compare, optRow);
  let nulls2 = List.empty<Nat>();
  for ((id, _) in m.candidatesEq("tag", #null_)) { nulls2.add(id) };
  assert eq(Array.sort(nulls2.toArray(), Nat.compare), [0, 2, 6, 8, 10]);
  // and clearing id 1's tag → it enters the null bucket
  m.put(1, { id = 1; tag = "" }, Nat.compare, optRow);
  assert (do { var found = false; for ((id, _) in m.candidatesEq("tag", #null_)) { if (id == 1) found := true }; found });
});

// ── multiple independent single-column indexes ──────────────────────────────

test("two indexes are maintained independently", func () {
  let m = fresh();
  // moving a row's amount must not disturb the kind index, and vice-versa.
  let burnBefore = idsSorted(m.candidatesEq("kind", #text("burn")), func r = r.kind == "burn");
  m.put(0, { id = 0; kind = "burn"; amount = 777; note = "" });  // 0 stays burn, amount changes
  let burnAfter = idsSorted(m.candidatesEq("kind", #text("burn")), func r = r.kind == "burn");
  assert eq(burnBefore, burnAfter);                                          // kind index untouched
  assert eq(idsSorted(m.candidatesEq("amount", #nat(777)), func r = r.amount == 777), [0]);  // amount index updated
});

// ── read API mirrors the underlying map ─────────────────────────────────────

test("get / size / values / entries reflect the current contents", func () {
  let m = fresh();
  assert m.size() == 20;
  assert m.get(7) == ?(mk(7));
  assert m.get(99) == null;
  m.delete(7);
  assert m.size() == 19;
  assert m.get(7) == null;
  var count = 0;
  for (_ in IndexedMap.values(m)) { count += 1 };
  assert count == 19;
});
