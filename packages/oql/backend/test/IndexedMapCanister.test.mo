/// End-to-end PocketIC test: `IndexedMap` as real deployed canister state,
/// driven through actual update (`add`/`remove`) and query (`*Index`/`*Scan`)
/// message calls. It proves the index is maintained correctly under the real IC
/// execution model (EOP, replica) — not just the interpreter — and runs the
/// same differential oracle (index-served == scan) across the wire after
/// inserts, an update that moves an indexed key, and a delete.

import { test } "mo:test/async";
import Array        "mo:core/Array";
import IndexedStore "./fixtures/IndexedStore";

actor {

  func eqA(a : [Nat], b : [Nat]) : Bool = Array.equal(a, b, Nat.equal);

  public func runTests() : async () {
    let store = await (with cycles = 10_000_000_000_000) IndexedStore.IndexedStore();

    // seed: ages 30/40/25/50, emails a@x (×2), b@x, c@x
    await store.add(1, "a@x", 30);
    await store.add(2, "b@x", 40);
    await store.add(3, "a@x", 25);
    await store.add(4, "c@x", 50);

    await test("index-served queries agree with scan over deployed state", func () : async () {
      assert (await store.size()) == 4;
      // differential oracle across the wire
      assert eqA(await store.ageAtLeastIndex(30), await store.ageAtLeastScan(30));
      assert eqA(await store.byEmailIndex("a@x"), await store.byEmailScan("a@x"));
      // and the concrete answers
      assert eqA(await store.ageAtLeastIndex(30), [1, 2, 4]);
      assert eqA(await store.byEmailIndex("a@x"), [1, 3]);
    });

    await test("update via an update call moves the row in the index", func () : async () {
      await store.add(3, "a@x", 60);   // age 25 -> 60 (moves the age index)
      assert eqA(await store.ageAtLeastIndex(30), await store.ageAtLeastScan(30));
      assert eqA(await store.ageAtLeastIndex(30), [1, 2, 3, 4]);
      assert eqA(await store.ageAtLeastIndex(55), [3]);        // only 3 (60) clears 55; 4 is 50
      assert eqA(await store.byEmailIndex("a@x"), [1, 3]);     // email index unaffected
    });

    await test("delete via an update call removes the row from every index", func () : async () {
      await store.remove(1);
      assert (await store.size()) == 3;
      assert eqA(await store.byEmailIndex("a@x"), await store.byEmailScan("a@x"));
      assert eqA(await store.byEmailIndex("a@x"), [3]);        // 1 gone, 3 remains
      assert eqA(await store.ageAtLeastIndex(30), [2, 3, 4]);  // 1 gone from age index too
    });
  };
};
