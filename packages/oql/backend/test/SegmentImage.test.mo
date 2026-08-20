/// Differential oracle for the segment image path: the same rows written
/// row-at-a-time (`append` + `flush`) and written as a pre-built image
/// (`Image.build` + `appendSegmentImage`) must produce the SAME segment.
///
/// For a fixed-width table that is checked at the byte level — every column's
/// `[bitmap | values]` block must compare equal between the two stores — which is
/// the property the whole format rests on: if the bytes match, the image can be
/// copied in rather than decoded row by row, and every existing read path works
/// on it unchanged. Footers are compared too, since they are what serves `sum`,
/// `avg` and the zone map.
///
/// Footers are the sharper half of that claim now that they arrive in the image's
/// trailer rather than being derived on-chain: comparing them against what `flush`
/// computes is what stands behind the canister trusting a producer's numbers.
///
/// A text column is compared at the value level (every cell, plus footers)
/// rather than byte-wise. The blocks are laid out identically, but only the cell
/// contents are a claim worth pinning — the packed-byte padding is layout, not
/// meaning.
///
/// Malformed images are checked to be REJECTED, not tolerated: an image is
/// written into the Region before it is validated, so the guarantee under test is
/// that nothing is committed when validation fails.
/// Runs under PocketIC because it uses a Region.
import { test } "mo:test/async";
import Array "mo:core/Array";
import Int64 "mo:core/Int64";
import List "mo:core/List";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Region "mo:core/Region";
import Cell "../src/columnar/Cell";
import Columnar "../src/columnar/Columnar";
import Image "../src/columnar/Image";
import Table "../src/Table";

actor {

  let N = 1_000;

  // Fixed-width shape: [ #nat, #int, #float, #bool ]. Columns 0 and 2 carry
  // nulls, so the validity bitmap is exercised on both sides rather than being
  // all-ones by accident.
  let FIXED : [Cell.ColType] = [#nat, #int, #float, #bool];
  func fixedCell(r : Nat, c : Nat) : ?Cell.Cell = switch c {
    case 0 { if (r % 4 == 0) null else ?#nat(Nat64.fromNat(r * 10)) };
    case 1 { ?#int(Int64.fromIntWrap(-r)) };
    case 2 { if (r % 5 == 0) null else ?#float(Int.toFloat(r)) };
    case _ { ?#bool(r % 2 == 0) };
  };

  // [ #nat, #text ]; the text column holds variable-length values, some null and
  // some empty, so offsets repeat and the packed length is not word-aligned.
  let TEXT : [Cell.ColType] = [#nat, #text];
  func textCell(r : Nat, c : Nat) : ?Cell.Cell =
    if (c == 0) ?#nat(Nat64.fromNat(r))
    else if (r % 7 == 0) null
    else if (r % 11 == 0) ?#text("")
    else ?#text(rep("ab-", r % 5 + 1));

  // Varying-length text without a word-aligned total, so offsets repeat and the
  // packed bytes need padding.
  func rep(t : Text, n : Nat) : Text {
    var out = "";
    var k = 0;
    while (k < n) { out #= t; k += 1 };
    out;
  };

  func rowAtATime(cols : [Cell.ColType], cell : (Nat, Nat) -> ?Cell.Cell) : Columnar.State {
    let s = Columnar.new(cols, 0, 0);   // manual flush: one segment, exactly N rows
    var r = 0;
    while (r < N) {
      ignore Columnar.append(s, Array.tabulate<?Cell.Cell>(cols.size(), func c = cell(r, c)));
      r += 1;
    };
    Columnar.flush(s);
    s;
  };

  func viaImage(cols : [Cell.ColType], cell : (Nat, Nat) -> ?Cell.Cell) : Columnar.State {
    let scratch = Region.new();
    let img = Image.build(scratch, cols, N, cell);
    let s = Columnar.new(cols, 0, 0);
    assert Columnar.appendSegmentImage(s, img) == 0;
    s;
  };

  func seg0(s : Columnar.State) : Columnar.Segment =
    switch (s.segments.get(0)) { case (?g) g; case null { assert false; loop {} } };

  func footersAgree(a : Columnar.State, b : Columnar.State) : Bool {
    let (sa, sb) = (seg0(a), seg0(b));
    if (sa.start != sb.start or sa.rows != sb.rows) return false;
    var c = 0;
    while (c < a.cols.size()) {
      let (fa, fb) = (sa.footers[c], sb.footers[c]);
      if (fa.count != fb.count or fa.nulls != fb.nulls) return false;
      // min/max compare through Cell.lt in both directions: equal ⟺ neither is
      // less than the other, which also handles the null (all-null column) case.
      let sameMin = switch (fa.min, fb.min) {
        case (null, null) true;
        case (?x, ?y) not Cell.lt(x, y) and not Cell.lt(y, x);
        case _ false;
      };
      let sameMax = switch (fa.max, fb.max) {
        case (null, null) true;
        case (?x, ?y) not Cell.lt(x, y) and not Cell.lt(y, x);
        case _ false;
      };
      if (not sameMin or not sameMax) return false;
      if (sa.liveCount[c] != sb.liveCount[c]) return false;
      let sameSum = switch (sa.liveSum[c], sb.liveSum[c]) {
        case (#int x, #int y) x == y;
        case (#float x, #float y) x == y;   // same values added in the same order
        case _ false;
      };
      if (not sameSum) return false;
      c += 1;
    };
    true;
  };

  public func runTests() : async () {
    await test("a fixed-width image lands byte-identical to a flushed segment", func() : async () {
    let a = rowAtATime(FIXED, fixedCell);
    let b = viaImage(FIXED, fixedCell);
    let (sa, sb) = (seg0(a), seg0(b));

    // A fixed-width column's block is exactly [bitmap | rows words], so its
    // length is known and the comparison needs no layout guessing.
    let blockLen = (N + 63) / 64 * 8 + N * 8;
    var c = 0;
    while (c < FIXED.size()) {
      let ba = Region.loadBlob(a.region, sa.colBase[c], blockLen);
      let bb = Region.loadBlob(b.region, sb.colBase[c], blockLen);
      assert ba == bb;
      c += 1;
    };
    assert footersAgree(a, b);
    assert Columnar.count(a) == Columnar.count(b);
  });

    await test("a text image agrees cell for cell with a flushed segment", func() : async () {
    let a = rowAtATime(TEXT, textCell);
    let b = viaImage(TEXT, textCell);
    assert footersAgree(a, b);
    var r = 0;
    while (r < N) {
      var c = 0;
      while (c < TEXT.size()) {
        let x = Columnar.getCell(a, r, c);
        let y = Columnar.getCell(b, r, c);
        let same = switch (x, y) {
          case (null, null) true;
          case (?#text s, ?#text t) s == t;
          case (?u, ?v) not Cell.lt(u, v) and not Cell.lt(v, u);
          case _ false;
        };
        assert same;
        c += 1;
      };
      r += 1;
    };
  });

    await test("an image is readable through the ordinary scan and folds", func() : async () {
    let a = rowAtATime(FIXED, fixedCell);
    let b = viaImage(FIXED, fixedCell);
    var seen = 0;
    for ((id, _row) in Columnar.scan(b)) { assert id == seen; seen += 1 };
    assert seen == N;
    var c = 0;
    while (c < FIXED.size()) {
      assert Columnar.countOf(a, c) == Columnar.countOf(b, c);
      c += 1;
    };
  });

    await test("several images append into one dense row space", func() : async () {
    let scratch = Region.new();
    let s = Columnar.new(FIXED, 0, 0);
    let img = Image.build(scratch, FIXED, N, fixedCell);
    assert Columnar.appendSegmentImage(s, img) == 0;
    assert Columnar.appendSegmentImage(s, img) == N;
    assert Columnar.appendSegmentImage(s, img) == 2 * N;
    assert Columnar.count(s) == 3 * N;
    // Row 0 of each image must be reachable at its own base, which is what
    // proves the per-segment column bases are right rather than accidentally
    // aliasing the first image.
    var k = 0;
    while (k < 3) {
      let got = Columnar.getCell(s, k * N + 1, 0);
      let want = fixedCell(1, 0);
      assert (switch (got, want) { case (?#nat x, ?#nat y) x == y; case _ false });
      k += 1;
    };
  });

    await test("segments sent out of order land at their own rows", func() : async () {
      // A producer with several images in flight cannot control which arrives first —
      // messages from one caller have no execution order. Each image states the row it
      // starts at, so one that arrives early waits until the gap before it fills, and
      // the rows end up where they belong whatever the order was.
      let N = 40;
      let s = Columnar.new(FIXED, 0, 0);
      let scratch = Region.new();
      // Three images over [0,N), [N,2N), [2N,3N), built from ABSOLUTE row indices so
      // the cell values identify the row they belong to.
      func img(first : Nat) : Blob =
        Image.build(scratch, FIXED, N, func (r : Nat, c : Nat) : ?Cell.Cell = fixedCell(first + r, c));
      let i0 = img(0);
      let i1 = img(N);
      let i2 = img(2 * N);

      // Middle first: nothing becomes visible, it is waiting on [0,N).
      assert Columnar.appendSegmentImageAt(s, i1, N) == N;
      assert Columnar.stagedCount(s) == 1;
      assert Columnar.count(s) == 0;

      // Last, still out of order: two waiting, still nothing visible.
      assert Columnar.appendSegmentImageAt(s, i2, 2 * N) == N;
      assert Columnar.stagedCount(s) == 2;
      assert Columnar.count(s) == 0;

      // The gap arrives: it promotes itself AND both waiters, in one drain.
      assert Columnar.appendSegmentImageAt(s, i0, 0) == N;
      assert Columnar.stagedCount(s) == 0;
      assert Columnar.count(s) == 3 * N;

      // Every row reads back the value built for that absolute position — the check
      // that a promoted segment kept its own rows rather than the ones at the frontier
      // when it arrived.
      var r = 0;
      while (r < 3 * N) {
        switch (Columnar.getRow(s, r)) {
          case (?cells) {
            var c = 0;
            while (c < FIXED.size()) { assert cells[c] == fixedCell(r, c); c += 1 };
          };
          case null assert false;
        };
        r += 1;
      };
    });

    await test("a segment overlapping a staged one is refused, and staged segments can be dropped", func() : async () {
      // The failure this guards: a load stops with segments in flight. Its producer resumes
      // from the row count, which is the CONTIGUOUS frontier and sits behind anything still
      // staged, and re-chunks — so its next segment can span a staged one without sharing a
      // start. Placing it would strand the staged segment below the frontier, where nothing
      // can ever promote it and the rows it already acknowledged are gone.
      let N = 40;
      let s = Columnar.new(FIXED, 0, 0);
      let scratch = Region.new();
      func img(first : Nat, rows : Nat) : Blob =
        Image.build(scratch, FIXED, rows, func (r : Nat, c : Nat) : ?Cell.Cell = fixedCell(first + r, c));

      assert Columnar.appendSegmentImageAt(s, img(0, N), 0) == N;      // frontier 40
      assert Columnar.appendSegmentImageAt(s, img(2 * N, N), 2 * N) == N;   // staged [80,120)
      assert Columnar.stagedCount(s) == 1;

      // Resume re-chunks: 60 rows from the frontier spans the staged [80,120).
      func spanning() : async () { ignore Columnar.appendSegmentImageAt(s, img(N, 60), N) };
      var trapped = false;
      try { await spanning() } catch (_) { trapped := true };
      assert trapped;
      assert Columnar.stagedCount(s) == 1;                            // untouched
      assert Columnar.count(s) == N;                                  // and nothing lost

      // Recovery: drop what is waiting, then resume from the row count with any chunking.
      assert Columnar.dropStaged(s) == 1;
      assert Columnar.stagedCount(s) == 0;
      assert Columnar.appendSegmentImageAt(s, img(N, 60), N) == 60;
      assert Columnar.count(s) == N + 60;
      var r = 0;
      while (r < N + 60) {
        switch (Columnar.getRow(s, r)) {
          case (?cells) { var c = 0; while (c < FIXED.size()) { assert cells[c] == fixedCell(r, c); c += 1 } };
          case null assert false;
        };
        r += 1;
      };
    });

    await test("a segment behind the frontier is refused", func() : async () {
      // Those rows exist. Re-sending a different image for a filled range is a producer
      // bug, and staging cannot help — so it traps rather than being taken as a retry.
      let N = 16;
      let s = Columnar.new(FIXED, 0, 0);
      let scratch = Region.new();
      let i0 = Image.build(scratch, FIXED, N, fixedCell);
      assert Columnar.appendSegmentImageAt(s, i0, 0) == N;
      assert Columnar.count(s) == N;
      func again() : async () { ignore Columnar.appendSegmentImageAt(s, i0, 0) };
      var trapped = false;
      try { await again() } catch (_) { trapped := true };
      assert trapped;
    });

    await test("a mixed image and buffered rows keep row-ids dense", func() : async () {
    let scratch = Region.new();
    let s = Columnar.new(FIXED, 0, 0);
    // Buffered rows must be flushed ahead of an image, or the image's rows would
    // be interleaved with them.
    ignore Columnar.append(s, Array.tabulate<?Cell.Cell>(FIXED.size(), func c = fixedCell(0, c)));
    ignore Columnar.append(s, Array.tabulate<?Cell.Cell>(FIXED.size(), func c = fixedCell(1, c)));
    let img = Image.build(scratch, FIXED, N, fixedCell);
    assert Columnar.appendSegmentImage(s, img) == 2;
    assert Columnar.count(s) == N + 2;
    assert (switch (Columnar.getCell(s, 1, 1)) { case (?#int x) x == Int64.fromIntWrap(-1); case _ false });
    assert (switch (Columnar.getCell(s, 2 + 1, 1)) { case (?#int x) x == Int64.fromIntWrap(-1); case _ false });
  });

    await test("a row deleted while buffered keeps its cells in the segment it flushes into", func() : async () {
      // A flushed row's delete is logical: its bytes stay in the segment, which is
      // what lets an index committed later read the key its posting sits under. A
      // buffered delete must lose nothing either — so the flush writes the deleted
      // row's cells like any live row's and leaves the position a tombstone. It is
      // dead to every ordinary read and to every fold; only `rawRow`, the
      // reconcile path, still sees it.
      let ROWS = 130;                                   // > 64, so the dead row is not in the first validity word
      let DEAD = 70;
      let s = Columnar.new(FIXED, 0, 0);
      var r = 0;
      while (r < ROWS) {
        ignore Columnar.append(s, Array.tabulate<?Cell.Cell>(FIXED.size(), func c = fixedCell(r, c)));
        r += 1;
      };
      Columnar.delete(s, DEAD);
      Columnar.delete(s, DEAD);                         // idempotent: the stash keeps the first cells
      Columnar.flush(s);

      // Dead to the reads and the folds — identical to a table that never held it.
      assert Columnar.count(s) == ROWS - 1;
      assert Columnar.getRow(s, DEAD) == null;
      assert (switch (Columnar.reader(s, DEAD)) { case null true; case (?_) false });
      var seen = 0;
      for ((id, _row) in Columnar.scan(s)) { assert id != DEAD; seen += 1 };
      assert seen == ROWS - 1;

      // The footers exclude it: `count + nulls == rows` still holds, and every
      // fold matches a store built without the row at all.
      let want = Columnar.new(FIXED, 0, 0);
      r := 0;
      while (r < ROWS) {
        if (r != DEAD) ignore Columnar.append(want, Array.tabulate<?Cell.Cell>(FIXED.size(), func c = fixedCell(r, c)));
        r += 1;
      };
      Columnar.flush(want);
      var c = 0;
      while (c < FIXED.size()) {
        let f = seg0(s).footers[c];
        assert f.count + f.nulls == ROWS;
        assert Columnar.countOf(s, c) == Columnar.countOf(want, c);
        assert Columnar.minOf(s, c) == Columnar.minOf(want, c);
        assert Columnar.maxOf(s, c) == Columnar.maxOf(want, c);
        assert (switch (Columnar.sumOf(s, c), Columnar.sumOf(want, c)) {
          case (#int x, #int y) x == y;
          case (#float x, #float y) x == y;
          case _ false;
        });
        c += 1;
      };

      // But its cells are in the segment, which is what an index commit reads.
      switch (Columnar.rawRow(s, DEAD)) {
        case (?cells) { var i = 0; while (i < FIXED.size()) { assert cells[i] == fixedCell(DEAD, i); i += 1 } };
        case null assert false;
      };
    });

    await test("a block length that disagrees with the rows is rejected", func() : async () {
    let scratch = Region.new();
    let img = Image.build(scratch, FIXED, 64, fixedCell);
    let len = Nat64.fromNat(img.size());
    switch (Image.validate(scratch, 0, len, FIXED)) {
      case (#ok _) {};
      case (#err _) assert false;
    };
    // Shrink the first column's block by one word. Nothing about the bytes is
    // otherwise wrong, so this is caught by the layout checks alone — there is no
    // checksum to fall back on, by design.
    let d = Image.HEADER + 12;
    Region.storeNat32(scratch, d, Region.loadNat32(scratch, d) - 8);
    switch (Image.validate(scratch, 0, len, FIXED)) {
      case (#err _) {};
      case (#ok _) assert false;
    };
  });

    await test("a table with a declared index refuses a segment image", func() : async () {
    let scratch = Region.new();
    let img = Image.build(scratch, [#nat, #nat], 8,
      func (r : Nat, c : Nat) : ?Cell.Cell = ?#nat(Nat64.fromNat(r * 10 + c)));
    // Indexed: the decl is ready from construction, so an image load would leave
    // the planner routing to postings that miss every loaded row. Must trap.
    // (The trap crosses an async boundary here so the test can observe it.)
    let indexed = Table.new([("a", #nat), ("b", #nat)], [("a", #hash)]);
    func attempt() : async () { ignore Table.loadSegment(indexed, img) };
    var trapped = false;
    try { await attempt() } catch (_) { trapped := true };
    assert trapped;
    assert Table.size(indexed) == 0;
    // Index-free: the same image loads, and the rows serve.
    let plain = Table.new([("a", #nat), ("b", #nat)], []);
    assert Table.loadSegment(plain, img) == 0;
    assert Table.size(plain) == 8;
  });

    await test("a footer count that disagrees with the rows is rejected", func() : async () {
    let scratch = Region.new();
    let img = Image.build(scratch, FIXED, 64, fixedCell);
    let len = Nat64.fromNat(img.size());
    // live + nulls must equal rows. It is the one footer field the canister can
    // check without scanning, and a wrong live count would make `avg` divide by a
    // denominator no scan could produce.
    let t = Image.HEADER + Image.DIRENT * Nat64.fromNat(FIXED.size());
    Region.storeNat64(scratch, t, Region.loadNat64(scratch, t) + 1);
    switch (Image.validate(scratch, 0, len, FIXED)) {
      case (#err _) {};
      case (#ok _) assert false;
    };
  });

  };
};
