/// Proves the Region cap accommodates the columnar store: growth past the old
/// 4 GiB (65536-page) limit — within moc 1.14's 1638400-page (100 GiB) default,
/// so no --max-stable-pages flag is needed in consuming projects.
import { test } "mo:test/async";
import Region "mo:core/Region";

actor {
  public func runTests() : async () {
    await test("Region grows past the 65536-page (4 GiB) default", func() : async () {
      let r = Region.new();
      let target : Nat64 = 70_000;                 // > 65536 → beyond the old 4 GiB cap
      let old = Region.grow(r, target);
      assert old != 0xFFFF_FFFF_FFFF_FFFF;         // 0xFFFF… ⟺ grow failed
      assert Region.size(r) == target;
      let hi : Nat64 = 65_600 * 65_536;            // offset in page 65600 (~4.004 GiB)
      Region.storeNat64(r, hi, 42);
      assert Region.loadNat64(r, hi) == 42;
    });
  };
};
