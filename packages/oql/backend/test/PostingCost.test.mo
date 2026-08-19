/// A posting must cost the same per operation regardless of how many refs it
/// holds, for the workload the columnar backend actually generates: append the
/// newest row, delete the oldest. Both land at an end of the sorted window, so
/// both should move no elements.
///
/// This exists because the obvious implementation of "keep the window packed"
/// fails exactly here, and only at sizes where `count` equals the array's
/// capacity — so it hides completely unless the sizes below are powers of two. When the window sits flush against the top of its array
/// with free space below, sliding it down recovers only as many slots as have
/// been freed at the front — one, in this workload — so a naive slide-whenever-
/// full pays a full O(count) copy per insert, forever, and never grows out of
/// it. The cost is invisible at small sizes and fatal at large ones, so the
/// assertion below compares per-operation cost across a 10x size difference
/// rather than measuring any absolute number.
import { test } "mo:test/async";
import Prim    "mo:⛔";
import Nat     "mo:core/Nat";
import Nat64   "mo:core/Nat64";
import Debug   "mo:core/Debug";
import Posting "../src/Posting";

actor {
  // Fill a posting with `k` ascending refs, then run `cycles` of
  // (delete oldest, append newest) and return the instructions that took.
  func rollingCost(k : Nat, cycles : Nat) : Nat {
    let p = Posting.empty<Nat>();
    var i = 0;
    while (i < k) { p.add(Nat.compare, i); i += 1 };
    // Warm up past the one-time capacity growth the first cycle triggers, so
    // what follows measures the steady state rather than that copy amortised
    // over however many cycles we happen to run.
    var w = 0;
    while (w < k) { ignore p.remove(Nat.compare, w); p.add(Nat.compare, k + w); w += 1 };
    let before = Prim.performanceCounter(0);
    var c = 0;
    while (c < cycles) {
      ignore p.remove(Nat.compare, k + c);   // the front: smallest live ref
      p.add(Nat.compare, 2 * k + c);         // the back: largest ref
      c += 1;
    };
    let after = Prim.performanceCounter(0);
    assert p.size() == k;
    Nat64.toNat(after - before);
  };

  public func runTests() : async () {
    await test("a rolling append/delete-oldest costs the same per op at 10x the size", func() : async () {
      // Sizes are exact powers of two: capacity doubles, so `count == capacity`
      // leaves NO slack above the window, which is the case where a slide
      // recovers only the single slot the front-delete freed.
      let cycles = 200;
      let small = rollingCost(2_048, cycles);
      let large = rollingCost(16_384, cycles);
      Debug.print("posting rolling cost: k=2,048 -> " # Nat.toText(small)
        # " instrs; k=16,384 -> " # Nat.toText(large) # " (per op: "
        # Nat.toText(small / cycles) # " vs " # Nat.toText(large / cycles) # ")");
      // The regression this guards against is O(count) per operation: an 8x
      // larger posting then costs about 8x more per op, scaling with the refs
      // rather than staying flat. The sorted-array version grows far less, though
      // not flatly — the two O(log count) binary searches per cycle only partly
      // explain the remainder, which is not characterised — so the threshold sits
      // between the two rather than asserting flatness.
      assert large < small * 4;
    });

    await test("refs stay sorted, deduped and complete through the rolling workload", func() : async () {
      let p = Posting.empty<Nat>();
      var i = 0;
      while (i < 500) { p.add(Nat.compare, i); i += 1 };
      var c = 0;
      while (c < 500) {
        ignore p.remove(Nat.compare, c);
        p.add(Nat.compare, 500 + c);
        p.add(Nat.compare, 500 + c);      // duplicate: must be a no-op
        c += 1;
      };
      assert p.size() == 500;
      // The live refs must be exactly 500..999, ascending.
      var expect = 500;
      for (r in p.values()) { assert r == expect; expect += 1 };
      assert expect == 1_000;
    });
  };
};
