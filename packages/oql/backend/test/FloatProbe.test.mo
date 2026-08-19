/// Regression for issue #45: a float-encoded `#eq`/`#in_` probe against an
/// integer-keyed indexed column silently under-fetched at values >= 2^53,
/// because the `Float`↔`Int` bridge in `Predicate.compare` went through the
/// lossy `Float.fromInt` — making one float `#equal` to two distinct integer
/// keys, so an ordered-map point probe landed on one bucket and dropped the
/// other while a scan matched both. The bridge is now EXACT, so `compare` is a
/// valid total order again and index == scan by construction.

import { test } "mo:test";
import Nat         "mo:core/Nat";
import IndexedMap  "../src/IndexedMap";
import Predicate   "../src/Predicate";
import OQL         "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _BoolValue "../src/BoolValue";
import _NatValue "../src/NatValue";
import _RecordValue "../src/RecordValue";

type R = { id : Nat; amount : Nat };

let two53 : Nat = 9_007_199_254_740_992;   // 2^53

test("Float↔Int compare is exact at and past 2^53", func () {
  // The float 2^53 is representable; it equals the integer 2^53 and is strictly
  // less than 2^53 + 1 (the old lossy bridge called both #equal).
  assert Predicate.compare(#float(9007199254740992.0), #nat(two53)) == #equal;
  assert Predicate.compare(#float(9007199254740992.0), #nat(two53 + 1)) == #less;
  assert Predicate.compare(#nat(two53 + 1), #float(9007199254740992.0)) == #greater;
  // 2^53 + 1 is NOT float-representable — the literal rounds to 2^53.
  assert Predicate.compare(#float(9007199254740993.0), #nat(two53)) == #equal;
});

test("Float↔Int compare is unchanged below 2^53", func () {
  assert Predicate.compare(#float(3.0), #nat(3)) == #equal;
  assert Predicate.compare(#float(3.5), #nat(3)) == #greater;
  assert Predicate.compare(#float(3.5), #nat(4)) == #less;
  assert Predicate.compare(#int(-3), #float(-2.5)) == #less;      // -3 < -2.5
  assert Predicate.compare(#float(-2.5), #int(-2)) == #less;      // -2.5 < -2
  assert Predicate.compare(#float(-2.5), #int(-3)) == #greater;   // -2.5 > -3
});

test("total order holds across encodings and non-finite floats", func () {
  let nan = 0.0 / 0.0;
  let inf = 1.0 / 0.0;
  // Non-finite floats keep the float↔float order (NaN greatest, ±inf extremes),
  // now also against integers.
  assert Predicate.compare(#float(inf), #nat(5)) == #greater;
  assert Predicate.compare(#nat(5), #float(inf)) == #less;
  assert Predicate.compare(#float(-inf), #int(-5)) == #less;
  assert Predicate.compare(#float(nan), #nat(5)) == #greater;
  assert Predicate.compare(#float(nan), #float(inf)) == #greater;
  // Transitivity across all three encodings at the magnitude that used to break:
  // float 2^53 == nat 2^53 == int 2^53, and all < nat (2^53 + 1).
  assert Predicate.compare(#float(9007199254740992.0), #nat(two53)) == #equal;
  assert Predicate.compare(#nat(two53), #int(two53)) == #equal;
  assert Predicate.compare(#float(9007199254740992.0), #int(two53)) == #equal;   // transitive
  assert Predicate.compare(#float(9007199254740992.0), #nat(two53 + 1)) == #less;
  // -0.0 shares the zero equivalence class across encodings.
  assert Predicate.compare(#float(-0.0), #nat(0)) == #equal;
});

test("float #eq probe at 2^53: index-served == scan", func () {
  let m = IndexedMap.new<Nat, R>([("amount", #ordered)]);
  m.put(0, { id = 0; amount = two53 });
  m.put(1, { id = 1; amount = two53 + 1 });
  let probe : OQL.Value = #float(9007199254740992.0);

  var scan = 0;
  for ((_, r) in m.entries()) { if (Predicate.compare(#nat(r.amount), probe) == #equal) scan += 1 };
  var served = 0;
  for (_ in m.candidatesEq("amount", probe, Nat.compare)) { served += 1 };

  assert scan == served;   // the divergence is gone
  assert served == 1;      // exact: the 2^53 probe matches 2^53 only, not 2^53 + 1
});

test("float #in_ probe at 2^53: index-served == scan", func () {
  let m = IndexedMap.new<Nat, R>([("amount", #ordered)]);
  m.put(0, { id = 0; amount = two53 });
  m.put(1, { id = 1; amount = two53 + 1 });
  let keys : [OQL.Value] = [#float(9007199254740992.0), #float(9007199254740993.0)];  // both round to 2^53

  var scan = 0;
  for ((_, r) in m.entries()) {
    if (keys.values().any(func (k : OQL.Value) : Bool = Predicate.compare(#nat(r.amount), k) == #equal)) scan += 1;
  };
  var served = 0;
  for (_ in m.candidatesIn("amount", keys, Nat.compare)) { served += 1 };

  assert scan == served;
  assert served == 1;      // both keys are the float 2^53 → the 2^53 row only
});
