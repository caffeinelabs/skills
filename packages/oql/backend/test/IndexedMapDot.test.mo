/// Confirms the fully-implicit call: with the receiver named `self` and the
/// lineariser param named `_toRow`, `m.put(k, v)` derives BOTH `compare` (from
/// K) and `_toRow` (the __record combiner over V) — no explicit args.
import { test } "mo:test";
import Nat        "mo:core/Nat";
import List       "mo:core/List";
import IndexedMap "../src/IndexedMap";
import OQL        "../src";  // brings the `_toRow` instances (NatValue/TextValue/RecordValue)
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";

type U = { id : Nat; kind : Text };

test("m.put(k, v) with no explicit compare/_toRow", func () {
  let m = IndexedMap.new<Nat, U>([("kind", #hash)]);

  m.put(1, { id = 1; kind = "a" });     // both implicits derived
  m.put(2, { id = 2; kind = "b" });
  m.put(3, { id = 3; kind = "a" });

  assert m.size() == 3;

  let ids = List.empty<Nat>();
  for ((k, u) in m.candidatesEq("kind", #text("a"))) { if (u.kind == "a") ids.add(k) };
  assert ids.size() == 2;

  m.delete(2);                          // derived too
  assert m.size() == 2;

  // keep OQL referenced so the import (which supplies the instances) isn't "unused"
  assert OQL.Types.pathToText(["x"]) == "x";
});
