/// The commit-time guards, proven by breaking them: a malformed segment or a
/// segment set that does not tile the loaded rows must never serve a wrong answer.
///
///   - coverage guard (generalised): a column's segments must tile `[0, appended)`
///     exactly. A segment that starts off the running coverage end (a gap or
///     overlap) traps at commit; a set that stops short of `appended` leaves the
///     column PENDING, so queries scan (a correct superset) instead of
///     under-fetching the uncovered tail. Both are checked here, and the pending
///     path is shown to still answer correctly.
///   - probe reachability: every occupied bucket must be reachable from its home
///     within `maxProbe`; otherwise a reader stops short and silently misses a key.
///     (`HashSegment.validate`, the off-line audit.)
///   - dropped null run: the null run plus the key runs must tile the segment's
///     range; a producer that dropped the nulls (empty null run) is rejected by
///     the audit rather than under-fetching every `eq(col,null)`.
///   - putIndexChunk expect-offset: an out-of-order chunk traps.
///   - reopen (the delta load): a column reopened for extension keeps its coverage
///     and its tiling rule — a segment at the old start, or one past `appended`,
///     still traps — and the reopen itself is refused when rows were APPENDED since
///     the column went ready, because those live in the heap delta and an extended
///     base would cover them a second time. The load gate is what forces EVERY
///     region-indexed column to be reopened, not just one.
///
/// Each guard, if reverted, lets a wrong answer through (verified by temporarily
/// removing the check). Runs under PocketIC because it uses Regions.
import { test } "mo:test/async";
import Array    "mo:core/Array";
import Blob     "mo:core/Blob";
import Nat64    "mo:core/Nat64";
import Region   "mo:core/Region";
import Runtime  "mo:core/Runtime";
import Cell     "../src/columnar/Cell";
import Columnar "../src/columnar/Columnar";
import HashSegment "../src/columnar/HashSegment";
import Image    "../src/columnar/Image";
import RegionIndex "../src/RegionIndex";
import Table    "../src/Table";
import OQL      "../src";

actor {

  let N = 256;
  let COLS : [Table.Column] = [("acct", #nat), ("amount", #nat)];
  func acctCell(r : Nat) : ?Cell.Cell = if (r % 11 == 0) null else ?#nat(Nat64.fromNat(r % 8));
  func imgCell(r : Nat, c : Nat) : ?Cell.Cell = if (c == 0) acctCell(r) else ?#nat(Nat64.fromNat(r % 100));
  func asRow(row : [(Text, OQL.Value)]) : [(Text, OQL.Value)] = row;

  // The segment bytes covering [first, first + count), positions absolute.
  func segBytes(first : Nat, count : Nat) : Blob {
    let ext = Region.new();
    HashSegment.build(ext, #nat, first, count, func (local : Nat) : ?Cell.Cell = acctCell(first + local));
  };

  // Load N rows into a fresh index-free table (an image), ready for segments.
  func loaded() : Table.Table {
    let a = Table.new(COLS, []);
    let img = Region.new();
    ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, imgCell));
    a;
  };

  // Upload a segment claiming to start at `claimFirst`, then commit it. `attempt`
  // runs the commit across an await so a trap is observable.
  func upload(a : Table.Table, claimFirst : Nat, bytes : Blob) {
    ignore Table.putIndexChunk(a, "acct", #hash, claimFirst, bytes.size(), 0, bytes);
  };

  // The same for the `amount` column, whose cells are `imgCell`'s second column.
  func uploadAmount(a : Table.Table, first : Nat, count : Nat) {
    let ext = Region.new();
    let bytes = HashSegment.build(ext, #nat, first, count, func (local : Nat) : ?Cell.Cell = ?#nat(Nat64.fromNat((first + local) % 100)));
    ignore Table.putIndexChunk(a, "amount", #hash, first, bytes.size(), 0, bytes);
  };

  // A second image of `count` rows continuing the generator from `from`.
  func loadMore(a : Table.Table, from : Nat, count : Nat) {
    let img = Region.new();
    ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], count, func (r : Nat, c : Nat) : ?Cell.Cell = imgCell(from + r, c)));
  };

  func rejected(region : Region.Region, len : Nat64) : Bool =
    switch (HashSegment.validate(region, 0, len, #nat, 0, N)) { case (#err _) true; case (#ok _) false };

  // Drive a reopen to completion: the canister absorbs its own appended rows a chunk at
  // a time, so the caller repeats until the column is reopened. `#none` is a failure
  // here — every use below expects a committed index to reopen.
  func driveReopen(a : Table.Table, col : Text) {
    var guard = 0;
    loop {
      switch (Table.reopenIndex(a, col)) {
        case (#reopened) break;
        case (#absorbing _) { guard += 1; if (guard > 1000) Runtime.trap("driveReopen: no progress") };
        case (#none) Runtime.trap("driveReopen: \"" # col # "\" had no committed index to reopen");
      };
    };
  };

  public func runTests() : async () {
    await test("an append during an extension is refused, so the ready flip means alignment", func() : async () {
      // The hole this closes: `coveredEnd == appended` at the ready flip only compares
      // COUNTS. An append and a segment row each add one position, so a row that entered
      // any other way during the window shifts every later position against its posting
      // while the arithmetic still balances — and a LATER load closes the gap and flips the
      // column ready over a base that describes the wrong rows. Refusing the append is what
      // makes segments the only way a position can enter, so the counts mean alignment.
      let a = loaded();
      upload(a, 0, segBytes(0, N));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
      // Driven to completion by the caller, a chunk at a time.
      var guard = 0;
      loop {
        switch (Table.reopenIndex(a, "acct")) {
          case (#reopened) break;
          case (#absorbing _) { guard += 1; assert guard < 100 };
          case (#none) Runtime.trap("reopenIndex: nothing to reopen");
        };
      };

      func appendNow() : async () { ignore Table.append(a, [("acct", #nat 3), ("amount", #nat 1)], asRow) };
      var trapped = false;
      try { await appendNow() } catch (_) { trapped := true };
      assert trapped;
      assert Table.appended(a) == N;                      // nothing entered

      // The extension itself still works, and the column serves again afterwards.
      loadMore(a, N, 32);
      upload(a, N, segBytes(N, 32));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
      assert Table.appended(a) == N + 32;

      // And once complete, appends are accepted again.
      ignore Table.append(a, [("acct", #nat 3), ("amount", #nat 1)], asRow);
      assert Table.appended(a) == N + 33;
    });

    await test("two segments tiling [0, N) make the column servable; one does not", func() : async () {
      let a = loaded();
      let half = N / 2;
      // First segment [0, half): committed, but the column is not yet tiled.
      upload(a, 0, segBytes(0, half));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == null;   // still pending → scans
      // Second segment [half, N): now tiled, the column serves.
      upload(a, half, segBytes(half, N - half));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
    });

    await test("coverage guard: a segment that leaves a GAP traps commit", func() : async () {
      let a = loaded();
      let half = N / 2;
      upload(a, 0, segBytes(0, half));
      ignore Table.commitIndex(a, "acct");
      // Claim the next segment starts past the covered end (a gap of 8 rows).
      upload(a, half + 8, segBytes(half, N - half));
      func attempt() : async () { ignore Table.commitIndex(a, "acct") };
      var trapped = false;
      try { await attempt() } catch (_) { trapped := true };
      assert trapped;
    });

    await test("coverage guard: a segment that OVERLAPS traps commit", func() : async () {
      let a = loaded();
      let half = N / 2;
      upload(a, 0, segBytes(0, half));
      ignore Table.commitIndex(a, "acct");
      // Claim the next segment starts before the covered end (an overlap of 8).
      upload(a, half - 8, segBytes(half, N - half));
      func attempt() : async () { ignore Table.commitIndex(a, "acct") };
      var trapped = false;
      try { await attempt() } catch (_) { trapped := true };
      assert trapped;
    });

    await test("coverage guard: a row appended between load and commit leaves the index unservable (no under-fetch)", func() : async () {
      let a = loaded();
      // Open the table for a write before committing — now appended = N + 1.
      ignore Table.append(a, [("acct", #nat 3), ("amount", #nat 1)], asRow);
      assert Table.appended(a) == N + 1;
      // The producer built a segment over only the loaded N rows.
      upload(a, 0, segBytes(0, N));
      ignore Table.commitIndex(a, "acct");   // succeeds, but coverage N < N+1
      // The column never became servable — so a query SCANS and still sees the
      // appended row. Breaking the readiness guard (marking ready at N != N+1)
      // would leave that row in neither base nor delta: a silent under-fetch.
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == null;
    });

    await test("probe reachability: an unreachable bucket is rejected by the audit", func() : async () {
      let ext = Region.new();
      let bytes = HashSegment.build(ext, #nat, 0, N, acctCell);
      let len = Nat64.fromNat(bytes.size());
      assert not rejected(ext, len);                       // valid to begin with
      // maxProbe lives at header offset 8. With keys present, dropping it to 0
      // makes every occupied bucket unreachable — the reachability check fires.
      Region.storeNat16(ext, 8, 0);
      assert rejected(ext, len);
    });

    await test("dropped null run: an emptied null run is rejected by the audit", func() : async () {
      let ext = Region.new();
      let bytes = HashSegment.build(ext, #nat, 0, N, acctCell);
      let len = Nat64.fromNat(bytes.size());
      assert not rejected(ext, len);
      // acctCell has nulls (r % 11), so the null run is non-empty. Claiming zero
      // nulls (nullLen at offset 60) leaves those loaded rows in no run at all —
      // the tile check rejects it rather than let eq(acct,null) under-fetch.
      assert Region.loadNat32(ext, 60) > 0;
      Region.storeNat32(ext, 60, 0);
      assert rejected(ext, len);
    });

    await test("putIndexChunk refuses a chunk that overlaps bytes already written", func() : async () {
      let a = loaded();
      let bytes = segBytes(0, N);
      let arr = Blob.toArray(bytes);
      let mid = arr.size() / 2 / 8 * 8;
      ignore Table.putIndexChunk(a, "acct", #hash, 0, arr.size(), 0, Blob.fromArray(Array.sliceToArray<Nat8>(arr, 0, mid)));
      // Chunks may arrive in any order, but each byte exactly once: a re-sent first chunk
      // overlaps what is already written, and accepting it would double-count coverage and
      // let commit pass over a segment with a hole elsewhere.
      func attempt() : async () { ignore Table.putIndexChunk(a, "acct", #hash, 0, arr.size(), 0, Blob.fromArray(Array.sliceToArray<Nat8>(arr, 0, mid))) };
      var trapped = false;
      try { await attempt() } catch (_) { trapped := true };
      assert trapped;
    });

    await test("a deleted buffered row cannot be inside a base that goes ready", func() : async () {
      // A buffered delete clears the row in place: it is not in the store's tombstone
      // set and its cells are gone. If the base went ready covering it, nothing could
      // ever mark its posting dead and `count` — pure run arithmetic — would report it
      // live for good. The commit that would complete the tiling traps instead.
      let a = loaded();
      ignore Table.append(a, [("acct", #nat 3), ("amount", #nat 1)], asRow);
      Table.delete(a, N);                       // the buffered row, now a hole
      assert Table.appended(a) == N + 1;
      upload(a, 0, segBytes(0, N + 1));         // a producer that covered it
      func attempt() : async () { ignore Table.commitIndex(a, "acct") };
      var trapped = false;
      try { await attempt() } catch (_) { trapped := true };
      assert trapped;
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == null;   // rolled back, still scanning

      // The trap rolled back its own message, not the upload staged before it, so the
      // segment is still staged — which is what `abortIndexUpload` is for.
      assert Table.abortIndexUpload(a);

      // Flushed, the same rows commit and serve: the delete is now a segment tombstone
      // the commit folds in.
      Table.flush(a);
      upload(a, 0, segBytes(0, N + 1));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
    });

    await test("declaring an index a committed column already has traps", func() : async () {
      // Committing the region base declares the column and marks it ready, so a
      // later on-chain build of the SAME column must be refused: its walk would add
      // a heap posting for every base row, and `count` adds base and delta, so each
      // loaded row would be counted twice. Adding an index on a DIFFERENT column
      // stays available — that is the on-chain path for indexes the producer did not
      // ship.
      let a = loaded();
      upload(a, 0, segBytes(0, N));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;   // ready ⟹ serving

      func again() : async () { ignore Table.addIndex(a, "acct", #hash) };
      var trapped = false;
      try { await again() } catch (_) { trapped := true };
      assert trapped;

      // A second column is still declarable, and starts pending (queries scan).
      ignore Table.addIndex(a, "amount", #hash);
      assert OQL.SecondaryIndex.kindOf(a.ix, "amount") == null;
    });

    await test("reopen ABSORBS the rows appended since the commit, then extends normally", func() : async () {
      let a = loaded();
      upload(a, 0, segBytes(0, N));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;

      // The write a live canister makes between two ingests. Its posting is in the heap
      // delta at position N, and no producer can ever supply a segment for it — that row
      // was never in a file. Extending the base past N without dealing with it would put
      // the position in the base AND the delta, counted twice by `count`.
      // FIVE appended rows, so the absorb's chunk loop runs more than once at a small
      // ABSORB_SEG — several segments tiling the gap are as valid as one.
      var w = 0;
      while (w < 5) { ignore Table.append(a, ([("acct", #nat 3), ("amount", #nat 1)] : [(Text, OQL.Value)]), asRow); w += 1 };
      assert Table.appended(a) == N + 5;
      assert RegionIndex.coveredTo(a.rix, 0) == N;

      // So the canister indexes that row itself, out of its own store, and the reopen
      // succeeds rather than refusing. Coverage reaches the row count, which is the
      // precondition an extension needs.
      driveReopen(a, "acct");
      assert RegionIndex.coveredTo(a.rix, 0) == N + 5;
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == null;   // reopened: the decl is gone

      // The absorbed row is in the BASE now, and in the base ONLY — its delta posting
      // went with the decl. `acct 3` holds the rows of [0, N) with that key plus this
      // one, counted once each.
      let e = switch (RegionIndex.servingEntry(a.rix, 0)) { case (?x) x; case null Runtime.trap("no serving entry") };
      var expect = 0;
      var r = 0;
      while (r < N) { if (acctCell(r) == ?#nat 3) expect += 1; r += 1 };
      assert RegionIndex.count(a.rix, e, HashSegment.keyOf(?#nat 3)) == expect + 5;

      // And the extension continues from there: a segment covering the next load's rows
      // starts at the absorbed frontier, not at N.
      loadMore(a, N + 5, N);
      upload(a, N + 5, segBytes(N + 5, N));
      ignore Table.commitIndex(a, "acct");
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;   // ready again
      assert RegionIndex.coveredTo(a.rix, 0) == 2 * N + 5;
    });

    // ── The absorb runs a CHUNK PER CALL, so it has to be able to CONTINUE. Accepting
    //    only a ready entry meant the first chunk left the column mid-absorb and every
    //    later call answered "nothing to do", wedging any gap bigger than one chunk.
    //    Small flush threshold ⟹ small absorb chunk ⟹ several chunks over a few rows.
    await test("an absorb larger than one chunk continues instead of wedging", func() : async () {
      let a = Table.newWith(COLS, [], [], 2);          // flush (and absorb) every 2 rows
      let img = Region.new();
      ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, imgCell));
      upload(a, 0, segBytes(0, N));
      ignore Table.commitIndex(a, "acct");

      var w = 0;
      while (w < 7) { ignore Table.append(a, ([("acct", #nat 3), ("amount", #nat 1)] : [(Text, OQL.Value)]), asRow); w += 1 };
      assert Table.appended(a) == N + 7;

      // Four calls at 2 rows a chunk, and it must report progress until it is through.
      var calls = 0;
      var absorbing = 0;
      loop {
        switch (Table.reopenIndex(a, "acct")) {
          case (#reopened) break;
          case (#absorbing left) { absorbing += 1; assert left < N + 7 };
          case (#none) Runtime.trap("the absorb wedged: #none with rows still to absorb");
        };
        calls += 1;
        assert calls < 50;
      };
      assert absorbing >= 2;                            // genuinely more than one chunk
      assert RegionIndex.coveredTo(a.rix, 0) == N + 7;

      var expect = 0;
      var r = 0;
      while (r < N) { if (acctCell(r) == ?#nat 3) expect += 1; r += 1 };
      let e = switch (RegionIndex.servingEntry(a.rix, 0)) { case (?x) x; case null Runtime.trap("no serving entry") };
      assert RegionIndex.count(a.rix, e, HashSegment.keyOf(?#nat 3)) == expect + 7;
    });

    // ── A row DELETED before it is absorbed must not come back as a live null. The
    //    store reports a tombstoned row's cell as null, so building from that filed it
    //    under the null run — while the DEAD fold probes with the row's REAL key, finds
    //    no posting there, and leaves it live. `eq(col, null)` then returned it forever.
    await test("a deleted appended row is absorbed dead, not as a live null", func() : async () {
      let a = loaded();
      upload(a, 0, segBytes(0, N));
      ignore Table.commitIndex(a, "acct");

      let nullsBefore = do {
        let e = switch (RegionIndex.readyEntry(a.rix, 0)) { case (?x) x; case null Runtime.trap("no entry") };
        RegionIndex.count(a.rix, e, null);
      };
      // A non-null key, appended and then deleted before any absorb sees it.
      let p = Table.append(a, ([("acct", #nat 3), ("amount", #nat 1)] : [(Text, OQL.Value)]), asRow);
      Table.delete(a, p);
      driveReopen(a, "acct");

      let e = switch (RegionIndex.servingEntry(a.rix, 0)) { case (?x) x; case null Runtime.trap("no serving entry") };
      // Not a null: it had a key. And not live under that key either — it is deleted.
      assert RegionIndex.count(a.rix, e, null) == nullsBefore;
      var expect = 0;
      var r = 0;
      while (r < N) { if (acctCell(r) == ?#nat 3) expect += 1; r += 1 };
      assert RegionIndex.count(a.rix, e, HashSegment.keyOf(?#nat 3)) == expect;
    });

    // ── The append itself is harmless; the NEXT load is where it corrupts. Two
    //    cursors are in play and they are the same number only while every row came
    //    from the file in order: the producer resumes its FILE read from the table's
    //    ROW COUNT, and labels each index segment with a POSITION.
    //
    //      file [A,B,C] -> positions 0,1,2;  append X -> position 3
    //      file grows to [A,B,C,D,E]: the load skips 4 file rows and sends only E, so
    //      D is never loaded and the table reads [A,B,C,X,E]. The index then resumes
    //      from its coverage and maps [B,C,D,E] onto positions 1..4 — claiming
    //      position 3 holds D when it holds X. Coverage and row count both reach 5, so
    //      the column goes READY misaligned: `eq X` misses it and counts report D.
    //
    //    Nothing downstream can notice — the arithmetic balances, exactly as in the
    //    reopen case. So the LOAD is refused once any position came from an append.
    await test("a load is refused once a row arrived by append, so the two cursors cannot drift", func() : async () {
      let a = loaded();                        // N rows, all from an image
      assert Columnar.imageRows(a.store) == N and Table.appended(a) == N;
      upload(a, 0, segBytes(0, N / 2));
      ignore Table.commitIndex(a, "acct");     // coverage stops short: pending
      // The ordinary write. Permitted — the column is pending, not reopened.
      ignore Table.append(a, ([("acct", #nat 3), ("amount", #nat 7)] : [(Text, OQL.Value)]), asRow);
      // THIS is the detectable state: one position did not come from a segment image,
      // so the producer's row count no longer names the file row it thinks it does.
      assert Table.appended(a) == N + 1 and Columnar.imageRows(a.store) == N;
      // `loadMore` here traps. It cannot be asserted in-process — a trap is not
      // catchable in the same message — so the trap itself is checked from the bench
      // harness; what is pinned here is the condition the guard reads.
      assert Table.appended(a) > Columnar.imageRows(a.store);
    });

    // ── An append during a PENDING first upload does not shift postings ON ITS OWN. The reopen
    //    guard exists because a reopened column's `coveredEnd == appended` compares only
    //    counts; a first upload is different, because the appended position is ABOVE
    //    every file row the producer will send, so the segments still describe the
    //    positions they claim. What it does is keep the column pending for good, which
    //    the partial-serving path answers correctly rather than wrongly.
    //    The segments still to come describe file rows BELOW the appended position, so
    //    they keep naming the positions they claim; what the append does is make
    //    `coveredEnd == appended` unreachable, leaving the column pending for good —
    //    which the prefix-plus-tail path answers correctly. The corruption needs the
    //    further load above, which is now refused.
    await test("an append during a pending first upload leaves the covered prefix correct", func() : async () {
      let a = loaded();                        // N rows, no index
      upload(a, 0, segBytes(0, N / 2));
      ignore Table.commitIndex(a, "acct");     // coveredEnd = N/2, appended = N: pending
      // A write arrives mid-upload. Allowed: the column is pending, not reopened.
      ignore Table.append(a, ([("acct", #nat 3), ("amount", #nat 7)] : [(Text, OQL.Value)]), asRow);
      assert Table.appended(a) == N + 1;
      // The remaining segment still covers the FILE rows [N/2, N), which are still at
      // positions [N/2, N) — the appended row sits above them.
      upload(a, N / 2, segBytes(N / 2, N / 2));
      ignore Table.commitIndex(a, "acct");
      let e = switch (RegionIndex.servingEntry(a.rix, 0)) { case (?x) x; case null Runtime.trap("no serving entry for acct") };
      assert e.coveredEnd == N;                 // covers every loaded row...
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == null;   // ...but not the appended one, so never ready
      // Every posting still names the row it describes: the base's live count over the
      // prefix equals the prefix's live size, and the appended row is left to the tail
      // scan rather than claimed by a segment.
      var total = RegionIndex.count(a.rix, e, null);
      var k = 0;
      while (k < 8) { total += RegionIndex.count(a.rix, e, HashSegment.keyOf(?#nat(Nat64.fromNat k))); k += 1 };
      assert total == N;
    });
  };
};
