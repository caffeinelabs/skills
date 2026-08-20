/// The #hash index-segment format: the Motoko reference `build` must
/// (a) produce bytes IDENTICAL to the off-chain producer for the same rows —
/// the cross-language conformance the region index trusts — (b) pass its own
/// `validate`, and (c) read back exactly what a brute-force scan of the rows
/// says for point / count / null / group. A mid-table segment (firstRow = N)
/// additionally checks the ABSOLUTE-position path: a segment built over
/// `[N, 2N)` must be byte-identical to the producer's and read back positions
/// shifted by N.
///
/// The fixture (`test/fixtures/HashSegmentFixture.mo`) is JS-built by
/// `tools/oql-ingest/gen-hash-fixture.mjs`; the row formulas below MUST match it.
/// Runs under PocketIC because it uses a Region.
import { test } "mo:test/async";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Region "mo:core/Region";
import Cell "../src/columnar/Cell";
import HashSegment "../src/columnar/HashSegment";
import F "./fixtures/HashSegmentFixture";
import Text "mo:core/Text";

actor {

  let N = F.rows;

  // Row formulas — kept in lockstep with gen-hash-fixture.mjs.
  func natCell(r : Nat) : ?Cell.Cell = if (r % 13 == 0) null else ?#nat(Nat64.fromNat((r * 7) % 12));
  func textCell(r : Nat) : ?Cell.Cell =
    if (r % 9 == 0) null
    else if (r % 5 == 0) ?#text("")
    else ?#text("k" # Nat.toText((r * 3) % 7));

  // Brute-force positions holding `key` (null = the null run), for the oracle.
  // `firstRow` is added to each matching local index so the oracle speaks in the
  // segment's absolute positions.
  func scanPositions(cell : (Nat) -> ?Cell.Cell, want : ?Cell.Cell, firstRow : Nat) : [Nat] {
    let out = List.empty<Nat>();
    var r = 0;
    while (r < N) {
      let same = switch (cell(r), want) {
        case (null, null) true;
        case (?#nat a, ?#nat b) a == b;
        case (?#text a, ?#text b) a == b;
        case _ false;
      };
      if (same) out.add(firstRow + r);
      r += 1;
    };
    out.toArray();
  };

  // Reconstruct the segment's positions for `key` via probe + positionAt.
  func segmentPositions(region : Region.Region, h : HashSegment.Header, key : ?HashSegment.Key) : [Nat] {
    let run = switch key { case null ?(h.nullStart, h.nullLen); case (?k) HashSegment.probe(region, h, k) };
    switch run {
      case null [];
      case (?(start, len)) {
        let out = List.empty<Nat>();
        var i = start;
        while (i < start + len) { out.add(HashSegment.positionAt(region, h, i)); i += 1 };
        out.toArray();
      };
    };
  };

  func eqNat(a : [Nat], b : [Nat]) : Bool {
    if (a.size() != b.size()) return false;
    var i = 0;
    while (i < a.size()) { if (a[i] != b[i]) return false; i += 1 };
    true;
  };

  public func runTests() : async () {
    await test("a #nat segment is byte-identical to the producer's, validates, and reads back exactly", func() : async () {
      let scratch = Region.new();
      let built = HashSegment.build(scratch, #nat, 0, N, natCell);
      assert built == Blob.fromArray(F.natSegment);

      let len = Nat64.fromNat(built.size());
      let h = switch (HashSegment.validate(scratch, 0, len, #nat, 0, N)) {
        case (#ok h) h;
        case (#err e) { assert false; loop {} };
      };
      // Every distinct key, plus the null run, reads back the scan's positions.
      var k = 0;
      while (k < 12) {
        assert eqNat(segmentPositions(scratch, h, ?#bits(Nat64.fromNat k)), scanPositions(natCell, ?#nat(Nat64.fromNat k), 0));
        k += 1;
      };
      assert eqNat(segmentPositions(scratch, h, null), scanPositions(natCell, null, 0));
      // A key never present probes to nothing.
      assert HashSegment.probe(scratch, h, #bits 999) == null;
    });

    await test("a mid-table #nat segment (firstRow = N) is byte-identical and reads back ABSOLUTE positions", func() : async () {
      let scratch = Region.new();
      let built = HashSegment.build(scratch, #nat, N, N, natCell);
      assert built == Blob.fromArray(F.natOffsetSegment);

      let len = Nat64.fromNat(built.size());
      let h = switch (HashSegment.validate(scratch, 0, len, #nat, N, N)) {
        case (#ok h) h;
        case (#err _) { assert false; loop {} };
      };
      // Positions come back shifted by N (absolute), matching the shifted oracle.
      var k = 0;
      while (k < 12) {
        assert eqNat(segmentPositions(scratch, h, ?#bits(Nat64.fromNat k)), scanPositions(natCell, ?#nat(Nat64.fromNat k), N));
        k += 1;
      };
      assert eqNat(segmentPositions(scratch, h, null), scanPositions(natCell, null, N));
      // Validating it against firstRow = 0 must FAIL — the positions land out of
      // the [0, N) range, proving the coverage/tile check reads firstRow.
      switch (HashSegment.validate(scratch, 0, len, #nat, 0, N)) { case (#err _) {}; case (#ok _) assert false };
    });

    await test("a #text segment is byte-identical to the producer's, validates, and reads back exactly", func() : async () {
      let scratch = Region.new();
      let built = HashSegment.build(scratch, #text, 0, N, textCell);
      assert built == Blob.fromArray(F.textSegment);

      let len = Nat64.fromNat(built.size());
      let h = switch (HashSegment.validate(scratch, 0, len, #text, 0, N)) {
        case (#ok h) h;
        case (#err _) { assert false; loop {} };
      };
      // The empty string and each "k#" key, plus nulls.
      assert eqNat(segmentPositions(scratch, h, ?#text("".encodeUtf8())), scanPositions(textCell, ?#text(""), 0));
      var k = 0;
      while (k < 7) {
        let key = "k" # Nat.toText(k);
        assert eqNat(segmentPositions(scratch, h, ?#text(key.encodeUtf8())), scanPositions(textCell, ?#text(key), 0));
        k += 1;
      };
      assert eqNat(segmentPositions(scratch, h, null), scanPositions(textCell, null, 0));
    });

    await test("validate rejects a corrupted magic and a wrong coverage", func() : async () {
      let scratch = Region.new();
      let built = HashSegment.build(scratch, #nat, 0, N, natCell);
      let len = Nat64.fromNat(built.size());
      // Good segment accepted.
      switch (HashSegment.validate(scratch, 0, len, #nat, 0, N)) { case (#ok _) {}; case (#err _) assert false };
      // Wrong coverage: claim the segment covers one more row than it does.
      switch (HashSegment.validate(scratch, 0, len, #nat, 0, N + 1)) { case (#err _) {}; case (#ok _) assert false };
      // Corrupt the magic.
      Region.storeNat32(scratch, 0, 0xDEAD_BEEF);
      switch (HashSegment.validate(scratch, 0, len, #nat, 0, N)) { case (#err _) {}; case (#ok _) assert false };
    });
  };
};
