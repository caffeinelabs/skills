/// Randomized differential oracle for `IndexedMap`. A deterministic LCG drives
/// a long sequence of `put`/`delete` over a small key space (so updates and
/// deletes actually hit live rows). After EVERY mutation, a battery of shapes
/// is checked: the index candidates (residual-filtered) must equal a full scan
/// of the SAME map (filtered) — so any stale, duplicate, or missing posting
/// introduced by any op is caught the moment it happens. Deterministic seed →
/// the run is reproducible.

import { test } "mo:test";
import Array    "mo:core/Array";
import List     "mo:core/List";
import Nat      "mo:core/Nat";
import Order    "mo:core/Order";
import IndexedMap "../src/IndexedMap";
import OQL      "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _BoolValue "../src/BoolValue";
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";

type R = { id : Nat; kind : Text; amount : Nat };

func kindName(n : Nat) : Text = if (n % 3 == 0) "burn" else if (n % 3 == 1) "mint" else "xfer";

func idsSorted(it : { next : () -> ?(Nat, R) }, pred : R -> Bool) : [Nat] {
  let acc = List.empty<Nat>();
  for ((k, r) in it) { if (pred(r)) acc.add(k) };
  Array.sort(acc.toArray(), Nat.compare)
};

func same(a : [Nat], b : [Nat]) : Bool = Array.equal(a, b, Nat.equal);

test("randomized differential oracle: index tracks the scan across put/delete", func () {
  let m = IndexedMap.new<Nat, R>([("kind", #hash), ("amount", #ordered)]);

  var seed : Nat = 2_463_534_242;
  func rnd() : Nat { seed := (seed * 1_103_515_245 + 12_345) % 2_147_483_648; seed };

  let KEYS = 25;

  // One shape: assert the index path equals the scan path over the current map.
  func check(pred : R -> Bool, cand : { next : () -> ?(Nat, R) }) {
    assert same(idsSorted(m.entries(), pred), idsSorted(cand, pred));
  };

  var op = 0;
  while (op < 300) {
    let k = rnd() % KEYS;
    if (rnd() % 3 == 2) {
      m.delete(k);   // ~1/3 deletes (many hit live rows given the small key space)
    } else {
      m.put(k, { id = k; kind = kindName(rnd()); amount = rnd() % 60 });
    };

    check(func r = r.kind == "burn",                       m.candidatesEq("kind", #text("burn")));
    check(func r = r.kind == "burn" or r.kind == "xfer",   m.candidatesIn("kind", [#text("burn"), #text("xfer")]));
    check(func r = r.amount >= 30,                         m.candidatesRange("amount", ?#nat(30), null, #asc));
    check(func r = r.amount < 20,                          m.candidatesRange("amount", null, ?#nat(20), #asc));
    check(func r = r.amount == 15,                         m.candidatesEq("amount", #nat(15)));
    check(func r = r.amount >= 10 and r.amount <= 40,      m.candidatesRange("amount", ?#nat(10), ?#nat(40), #asc));

    op += 1;
  };

  // After the churn, the ordered range must still be amount-asc / id-asc,
  // exactly a stable scan sort — proving ordering survives arbitrary mutation.
  let all = List.empty<(Nat, R)>();
  for (kv in m.entries()) { all.add(kv) };
  let sorted = Array.sort<(Nat, R)>(all.toArray(), func ((k1, r1), (k2, r2)) : Order.Order =
    switch (Nat.compare(r1.amount, r2.amount)) { case (#equal) Nat.compare(k1, k2); case o o });
  let expected = List.empty<Nat>();
  for ((k, _) in sorted.values()) { expected.add(k) };
  let actual = List.empty<Nat>();
  for ((k, _) in m.candidatesRange("amount", null, null, #asc)) { actual.add(k) };
  assert same(actual.toArray(), expected.toArray());
});
