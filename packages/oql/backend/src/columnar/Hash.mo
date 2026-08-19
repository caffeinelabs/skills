/// splitmix64's finaliser — the one hash the region index uses, bit-identical in
/// Motoko and the off-chain producer (`tools/oql-ingest/hash-segment.mjs`). It is
/// part of the hash index-segment format: changing it bumps the segment version.
///
/// The finaliser is exactly the three xor-shift-multiply steps that
/// `bench/scale/{image.mjs,main.mo}` already carry inside their `mix(k, salt)`
/// row generator — reused here without the seeding step, because a hash keys on
/// the cell bits themselves, not on a synthetic row index. `*%` wraps at 64 bits,
/// matching the JS side's `BigInt.asUintN(64, …)`.
///
/// No adversarial concern: bucket contents are fixed at build time, so a query
/// key can never lengthen a probe chain.
import Blob  "mo:core/Blob";
import Nat8  "mo:core/Nat8";

module {

  /// The splitmix64 finaliser over a 64-bit word.
  func mix(x0 : Nat64) : Nat64 {
    var x = x0;
    x := (x ^ (x >> 30)) *% 0xBF58_476D_1CE4_E5B9;
    x := (x ^ (x >> 27)) *% 0x94D0_49BB_1331_11EB;
    x ^ (x >> 31);
  };

  /// Hash of a fixed-width cell: the finaliser of its raw 64-bit word (a #nat's
  /// value, an #int's two's-complement bits, a #bool's 0/1) — the same bits the
  /// column store writes for that cell.
  public func fixed(bits : Nat64) : Nat64 = mix(bits);

  /// Hash of a text key: `mix(byteLen)`, then fold each 8-byte little-endian word
  /// of the UTF-8 bytes (the tail word zero-padded) as `h := mix(h ^ w)`. An
  /// empty string hashes to `mix(0)`.
  public func text(bytes : Blob) : Nat64 {
    let a = bytes.toArray();
    let n = a.size();
    var h = mix((n).toNat64());
    var i = 0;
    while (i < n) {
      var w : Nat64 = 0;
      var j = 0;
      while (j < 8 and i + j < n) {
        w := w | ((a[i + j]).toNat64() << (8 * (j).toNat64()));
        j += 1;
      };
      h := mix(h ^ w);
      i += 8;
    };
    h;
  };

};
