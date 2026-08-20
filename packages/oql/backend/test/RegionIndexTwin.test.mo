/// The correctness spine: a table served by a region `#hash` index must answer
/// exactly what a pure-heap `#hash` index answers, over identical rows and write
/// sequences, THROUGH THE UNTOUCHED EXECUTOR AND PLANNER. Both tables are queried
/// with the same OQL; `point`, `IN`, `count`, `groupCount`, `eq(col, null)`, and
/// `in [null, x]` must match at every stage:
///   load → commit → post-commit appends → base deletes → delta deletes,
/// and, for a DELTA load, load → commit → deletes → reopen → load more → deletes →
/// extension segments → appends → deletes.
///
/// `a` (region): rows loaded as a segment image, then a MULTI-SEGMENT hash index —
/// each segment built with the Motoko reference builder over its row range,
/// uploaded through the real `putIndexChunk` / `commitIndex`, tiling `[0, N)`.
/// Forcing several small segments is the point: a point query that missed one
/// segment's postings would silently under-fetch, so this multi-segment
/// differential is the correctness spine. `b` (heap): the same rows appended
/// row-at-a-time with the index declared up front (the maintenance path already
/// under test), the oracle.
/// Runs under PocketIC because it uses Regions.
import { test } "mo:test/async";
import Array    "mo:core/Array";
import Blob     "mo:core/Blob";
import Nat      "mo:core/Nat";
import Nat64    "mo:core/Nat64";
import Region   "mo:core/Region";
import Runtime "mo:core/Runtime";
import Text     "mo:core/Text";
import Cell     "../src/columnar/Cell";
import Columnar "../src/columnar/Columnar";
import List     "mo:core/List";
import HashSegment "../src/columnar/HashSegment";
import Image    "../src/columnar/Image";
import Table    "../src/Table";
import RegionIndex "../src/RegionIndex";
import Entity   "../src/Entity";
import OQL      "../src";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

actor {

  let N = 300;                       // loaded base rows
  let COLS : [Table.Column] = [("acct", #nat), ("amount", #nat)];

  // acct: ~8 distinct keys and nulls (r%11); amount rides along. The store cells
  // and the OQL row must agree for every position.
  func acctCell(r : Nat) : ?Cell.Cell = if (r % 11 == 0) null else ?#nat(Nat64.fromNat(r % 8));
  func imgCell(r : Nat, c : Nat) : ?Cell.Cell = if (c == 0) acctCell(r) else ?#nat(Nat64.fromNat(r * 7 % 100));
  func rowOf(r : Nat) : [(Text, OQL.Value)] = [
    ("acct", switch (acctCell(r)) { case (?#nat n) #nat(Nat64.toNat(n)); case _ #null_ }),
    ("amount", #nat(r * 7 % 100)),
  ];
  func asRow(row : [(Text, OQL.Value)]) : [(Text, OQL.Value)] = row;

  // ── query result comparison (borrowed from Table.test) ──────────────────────
  func valueKey(v : OQL.Value) : Text = switch v {
    case (#null_) "0"; case (#bool b) "1" # (if b "T" else "F");
    case (#nat n) "2" # Nat.toText(n); case (#int i) "3" # debug_show (i);
    case (#float f) "4" # debug_show (f); case (#text t) "5" # t;
  };
  func rowKey(row : [Executor.Cell]) : Text {
    var s = "";
    for (c in Array.sort(Array.map<Executor.Cell, Text>(row, func c = c.name # "=" # valueKey(c.value)), Text.compare).values()) { s := s # c # "|" };
    s;
  };
  func sameRows(a : [[Executor.Cell]], b : [[Executor.Cell]]) : Bool {
    if (a.size() != b.size()) return false;
    Array.sort(Array.map<[Executor.Cell], Text>(a, rowKey), Text.compare)
      == Array.sort(Array.map<[Executor.Cell], Text>(b, rowKey), Text.compare);
  };
  func unrestricted(_ : OQL.Decl) : OQL.Access = #unrestricted;

  // ── query shapes ────────────────────────────────────────────────────────────
  func base(where_ : ?OQL.Predicate.Predicate) : Query.Query =
    { start = "t"; where_; groupBy = []; aggregate = []; orderBy = []; offset = null; limit = null; select = null };
  func pointQ(v : OQL.Value) : Query.Query = base(?#eq(["acct"], v));
  func inQ(vs : [OQL.Value]) : Query.Query = base(?#in_(["acct"], vs));
  func countQ(v : OQL.Value) : Query.Query =
    { base(?#eq(["acct"], v)) with aggregate = [{ fn = #count; field = null; as_ = null }] };
  func groupQ() : Query.Query =
    { base(null) with groupBy = [["acct"]]; aggregate = [{ fn = #count; field = null; as_ = null }] };

  // min(col) / max(col) over the whole table, no predicate — the shape the planner
  // may answer from the store's footers.
  func minQ(col : Text) : Query.Query = { base(null) with aggregate = [{ fn = #min; field = ?[col]; as_ = null }] };
  func maxQ(col : Text) : Query.Query = { base(null) with aggregate = [{ fn = #max; field = ?[col]; as_ = null }] };

  // The single scalar an aggregate query returns.
  func scalar(r : Registry.Registry, q : Query.Query, name : Text) : OQL.Value {
    let rows = Executor.runWith(r, q, unrestricted).rows;
    assert rows.size() == 1;
    var out : OQL.Value = #null_;
    for (c in rows[0].values()) { if (c.name == name) out := c.value };
    out;
  };

  func agree(ra : Registry.Registry, rb : Registry.Registry, q : Query.Query) : Bool =
    sameRows(Executor.runWith(ra, q, unrestricted).rows, Executor.runWith(rb, q, unrestricted).rows);

  // Every access pattern the merge serves, at the current state of both twins.
  func agreeAll(ra : Registry.Registry, rb : Registry.Registry) : Bool {
    var v = 0;
    while (v < 8) {
      if (not agree(ra, rb, pointQ(#nat v))) return false;
      if (not agree(ra, rb, countQ(#nat v))) return false;
      v += 1;
    };
    agree(ra, rb, pointQ(#null_))                       // eq(acct, null)
      and agree(ra, rb, countQ(#null_))
      and agree(ra, rb, inQ([#nat 1, #nat 4, #nat 50])) // IN, incl. a key absent from base
      and agree(ra, rb, inQ([#null_, #nat 2]))          // in [null, x]
      and agree(ra, rb, pointQ(#nat 50))                // a key no base row holds
      and agree(ra, rb, groupQ());                      // groupBy acct -> count(*)
  };

  func regReg(t : Table.Table) : Registry.Registry = Registry.build([Entity.build(Table.entityWith(t, "t", "T", "id"))]);

  func stats(t : Table.Table) : Entity.ServedStats {
    let decl = Entity.build(Table.entityWith(t, "t", "T", "id"));
    switch (decl.served) {
      case (?served) switch (served.stats) {
        case (?s) s;
        case null Runtime.trap("stats: table has no served statistics");
      };
      case null Runtime.trap("stats: table is not served");
    };
  };

  func validEstimate(estimate : Entity.CountEstimate, exact : Nat, limit : Nat) : Bool =
    switch estimate {
      case (#exact n) n == exact;
      case (#atLeast n) n > limit and n <= exact;
    };

  func expectedUpTo(exact : Nat, limit : Nat) : Nat =
    if (exact <= limit) exact else limit + 1;

  func agreeCountUpTo(a : Table.Table, b : Table.Table, values : [OQL.Value]) : Bool {
    let sa = stats(a);
    let sb = stats(b);
    for (v in values.values()) {
      let exact = switch (sa.count("acct", v), sb.count("acct", v)) {
        case (?x, ?y) { if (x != y) return false; x };
        case _ return false;
      };
      for (limit in ([0, 1, 7, exact, exact + 1] : [Nat]).values()) {
        switch (sa.countUpTo("acct", v, limit), sb.countUpTo("acct", v, limit)) {
          case (?aEstimate, ?bEstimate) {
            if (not validEstimate(aEstimate, exact, limit) or not validEstimate(bEstimate, exact, limit)) return false;
          };
          case _ return false;
        };
      };
    };
    true;
  };

  func regionCountUpTo(t : Table.Table, v : OQL.Value, limit : Nat) : Nat {
    let e = switch (RegionIndex.servingEntry(t.rix, 0)) {
      case (?entry) entry;
      case null Runtime.trap("regionCountUpTo: acct is not serving");
    };
    let key : ?HashSegment.Key = switch v {
      case (#null_) null;
      case (#nat n) ?#bits(Nat64.fromNat(n));
      case _ Runtime.trap("regionCountUpTo: unsupported test value");
    };
    RegionIndex.countUpTo(t.rix, e, key, limit);
  };

  // Force several small index segments over N rows: a deliberately tiny segment
  // size, so the reader must union at least 3 segments to answer any query.
  let SEG = 100;                     // rows per index segment ⟹ N/SEG = 3 segments

  // Build `a`: load N rows as an image, then commit a MULTI-SEGMENT hash index
  // over `acct`, one segment per SEG-row block, tiling [0, N).
  func regionTable() : Table.Table {
    let a = Table.new(COLS, []);
    let img = Region.new();
    ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, imgCell));
    var first = 0;
    while (first < N) {
      let count = Nat.min(SEG, N - first);
      // Reference-build the segment over [first, first + count); postings absolute.
      let ext = Region.new();
      let bytes = HashSegment.build(ext, #nat, first, count, func (local : Nat) : ?Cell.Cell = acctCell(first + local));
      let arr = Blob.toArray(bytes);
      let mid = arr.size() / 2 / 8 * 8;                 // 8-aligned split, to exercise chunking
      ignore Table.putIndexChunk(a, "acct", #hash, first, arr.size(), 0, Blob.fromArray(Array.sliceToArray<Nat8>(arr, 0, mid)));
      ignore Table.putIndexChunk(a, "acct", #hash, first, arr.size(), mid, Blob.fromArray(Array.sliceToArray<Nat8>(arr, mid, arr.size())));
      ignore Table.commitIndex(a, "acct");
      first += count;
    };
    a;
  };

  // Commit one index segment over `[first, first + count)` of `a`.
  func commitSeg(a : Table.Table, first : Nat, count : Nat) {
    let ext = Region.new();
    let bytes = HashSegment.build(ext, #nat, first, count, func (local : Nat) : ?Cell.Cell = acctCell(first + local));
    ignore Table.putIndexChunk(a, "acct", #hash, first, bytes.size(), 0, bytes);
    ignore Table.commitIndex(a, "acct");
  };

  // The same index, but with a second image LOADED between commits. A column
  // whose segments do not yet tile `[0, appended)` is pending and declares no
  // decl, so `loadSegment` still accepts rows and `appended` grows before the
  // column goes ready — the base ends up larger than it was at the first commit.
  func regionTableInterleaved() : Table.Table {
    let a = Table.new(COLS, []);
    let img = Region.new();
    ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, imgCell));
    commitSeg(a, 0, SEG);                                 // pending: SEG < N
    let img2 = Region.new();
    ignore Table.loadSegment(a, Image.build(img2, [#nat, #nat], N, func (r : Nat, c : Nat) : ?Cell.Cell = imgCell(N + r, c)));
    var first = SEG;
    while (first < 2 * N) {
      let count = Nat.min(SEG, 2 * N - first);
      commitSeg(a, first, count);
      first += count;
    };
    a;
  };

  // ── a second shape, for cross-kind probes: a #bool key column ────────────────
  // `HashSegment.cellBits` maps #bool true and #nat 1 onto the same raw key, so a
  // #bool base probed with the #nat is what an aliasing bug looks like.
  let M = 60;
  let BCOLS : [Table.Column] = [("flag", #bool), ("amount", #nat)];
  func flagCell(r : Nat) : ?Cell.Cell = if (r % 7 == 0) null else ?#bool(r % 3 == 0);
  func bImgCell(r : Nat, c : Nat) : ?Cell.Cell = if (c == 0) flagCell(r) else ?#nat(Nat64.fromNat(r));
  func bRowOf(r : Nat) : [(Text, OQL.Value)] = [
    ("flag", switch (flagCell(r)) { case (?#bool b) #bool b; case _ #null_ }),
    ("amount", #nat r),
  ];

  func boolRegionTable() : Table.Table {
    let a = Table.new(BCOLS, []);
    let img = Region.new();
    ignore Table.loadSegment(a, Image.build(img, [#bool, #nat], M, bImgCell));
    let ext = Region.new();
    let bytes = HashSegment.build(ext, #bool, 0, M, func (local : Nat) : ?Cell.Cell = flagCell(local));
    ignore Table.putIndexChunk(a, "flag", #hash, 0, bytes.size(), 0, bytes);
    ignore Table.commitIndex(a, "flag");
    a;
  };

  func boolHeapTable() : Table.Table {
    let b = Table.new(BCOLS, [("flag", #hash)]);
    var r = 0;
    while (r < M) { ignore Table.append(b, bRowOf(r), asRow); r += 1 };
    Table.flush(b);
    b;
  };

  func countOf(q : Query.Query) : Query.Query = { q with aggregate = [{ fn = #count; field = null; as_ = null }] };

  func heapTable() : Table.Table = heapRows(N);

  func heapRows(rows : Nat) : Table.Table {
    let b = Table.new(COLS, [("acct", #hash)]);
    var r = 0;
    while (r < rows) { ignore Table.append(b, rowOf(r), asRow); r += 1 };
    Table.flush(b);
    b;
  };

  // A #float column holding NaN, min/max served versus scanned. `aggPlan` only serves
  // min/max when there is no predicate, so the same aggregate under an always-true
  // predicate takes the scan fold — which makes this a direct served-equals-scanned check.
  let NAN : Float = 0.0 / 0.0;
  func floatTable(vals : [Float]) : Table.Table {
    let t = Table.new([("score", #float)], []);
    for (v in vals.values()) ignore Table.append(t, [("score", #float v)], asRow);
    Table.flush(t);
    t;
  };
  func extreme(t : Table.Table, fn : Query.AggFn, scan : Bool) : OQL.Value {
    let r = regReg(t);
    let q : Query.Query = {
      base(if scan (?#ge(["id"], #nat 0)) else null) with
      aggregate = [{ fn; field = ?["score"]; as_ = null }]
    };
    Executor.runWith(r, q, unrestricted).rows[0][0].value;
  };

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
    await test("bounded region and table counts match the heap oracle", func() : async () {
      let a = regionTable();                              // three committed index segments
      let b = heapTable();
      let values : [OQL.Value] = [#nat 3, #null_, #nat 50];
      assert agreeCountUpTo(a, b, values);

      // RegionIndex.countUpTo itself is exact through the limit and returns the
      // sentinel immediately above it, including null and missing runs.
      let sa = stats(a);
      for (v in values.values()) {
        let exact = switch (sa.count("acct", v)) { case (?n) n; case null Runtime.trap("missing count") };
        for (limit in ([0, 1, exact, exact + 1] : [Nat]).values()) {
          assert regionCountUpTo(a, v, limit) == expectedUpTo(exact, limit);
        };
      };

      // Dead postings in every segment must be excluded from both exact and
      // early-exit results.
      for (p in ([3, 11, SEG + 3, 2 * SEG + 3] : [Nat]).values()) {
        Table.delete(a, p);
        Table.delete(b, p);
      };
      assert agreeCountUpTo(a, b, values);
      for (v in values.values()) {
        let exact = switch (stats(a).count("acct", v)) { case (?n) n; case null Runtime.trap("missing count") };
        assert regionCountUpTo(a, v, exact) == exact;
        if (exact > 0) assert regionCountUpTo(a, v, exact - 1) == exact;
      };
    });

    await test("bounded table count merges a serving prefix with its tail", func() : async () {
      let a = Table.new(COLS, []);
      let img = Region.new();
      ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, imgCell));
      commitSeg(a, 0, SEG);                               // serving prefix [0, SEG)
      let b = heapTable();
      let values : [OQL.Value] = [#nat 2, #null_, #nat 50];
      assert agreeCountUpTo(a, b, values);

      // One delete in the committed prefix and one in the unindexed tail.
      for (p in ([2, SEG + 2, SEG + 11] : [Nat]).values()) {
        Table.delete(a, p);
        Table.delete(b, p);
      };
      let added : [(Text, OQL.Value)] = [("acct", #nat 50), ("amount", #nat 1)];
      ignore Table.append(a, added, asRow);
      ignore Table.append(b, added, asRow);
      assert agreeCountUpTo(a, b, values);
    });

    await test("region vs heap agree through load, appends, base deletes, delta deletes", func() : async () {
      let a = regionTable();
      let b = heapTable();
      let ra = regReg(a);
      let rb = regReg(b);

      // Stage 1: base only.
      assert Table.appended(a) == N and Table.appended(b) == N;
      assert agreeAll(ra, rb);

      // Stage 2: post-commit appends (the delta), including a key absent from the
      // base (50), more nulls, and existing keys.
      let extra = [ (50, 1), (2, 9), (50, 2), (0, 0), (7, 3) ];   // (acct, amount); acct 50 is new
      for ((acct, amount) in extra.values()) {
        let row : [(Text, OQL.Value)] = [("acct", #nat acct), ("amount", #nat amount)];
        ignore Table.append(a, row, asRow);
        ignore Table.append(b, row, asRow);
      };
      // A post-commit null append on both.
      let nullRow : [(Text, OQL.Value)] = [("acct", #null_), ("amount", #nat 5)];
      ignore Table.append(a, nullRow, asRow);
      ignore Table.append(b, nullRow, asRow);
      assert agreeAll(ra, rb);

      // Stage 3: base deletes (positions < N) — a keyed row, a null row, and the
      // last of a key's run, on both twins. `a` sets DEAD bits; `b` drops postings.
      for (p in ([1, 5, 11, 22, 99, 231] : [Nat]).values()) { Table.delete(a, p); Table.delete(b, p) };
      // Re-delete one (idempotent DEAD / no-op heap).
      Table.delete(a, 1); Table.delete(b, 1);
      assert agreeAll(ra, rb);

      // Stage 4: delta deletes (post-commit positions >= N).
      Table.delete(a, N);       // the acct=50 row appended first
      Table.delete(b, N);
      Table.delete(a, N + 5);   // the post-commit null row
      Table.delete(b, N + 5);
      assert agreeAll(ra, rb);
    });

    await test("a reopened column extends over a second load and agrees with the twin throughout", func() : async () {
      // The delta upload: rather than re-sending the whole index for a table that has
      // grown, reopen the column, load the new rows, and cover only THEM with further
      // index segments continuing from the base's existing coverage. The answers must
      // match the heap oracle before the reopen, during the window (when the column is
      // in neither index half), and after the extension completes.
      let a = regionTable();                             // N rows loaded, base tiling [0, N)
      let b = heapTable();
      let ra = regReg(a);
      let rb = regReg(b);
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
      assert agreeAll(ra, rb);

      // Deletes BEFORE the second load — base rows, marked DEAD while ready.
      for (p in ([4, 11, 77] : [Nat]).values()) { Table.delete(a, p); Table.delete(b, p) };
      assert agreeAll(ra, rb);

      // Reopen. The base keeps every segment and its coverage — that number is where
      // the extension must continue — but the column is in NEITHER half now, so every
      // query below is answered by the scan over the store.
      driveReopen(a, "acct");
      assert RegionIndex.coveredTo(a.rix, 0) == N;
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == null;
      assert agreeAll(ra, rb);

      // The new data. `loadSegment` accepts it only because the reopen dropped the decl.
      let img2 = Region.new();
      ignore Table.loadSegment(a, Image.build(img2, [#nat, #nat], N, func (r : Nat, c : Nat) : ?Cell.Cell = imgCell(N + r, c)));
      var r = N;
      while (r < 2 * N) { ignore Table.append(b, rowOf(r), asRow); r += 1 };
      Table.flush(b);
      assert Table.appended(a) == 2 * N and Table.appended(b) == 2 * N;
      // Loaded but not yet covered by the extended base: the SCAN is what answers for
      // those rows, and it is a correct superset over old and new alike.
      assert agreeAll(ra, rb);

      // Deletes in flight: one in the old half (its DEAD bit waits for the tombstone
      // fold at the completing commit — `onDelete` skips a pending column) and one in
      // the new half, which no segment owns yet.
      for (p in ([5, N + 3] : [Nat]).values()) { Table.delete(a, p); Table.delete(b, p) };
      assert agreeAll(ra, rb);

      // The extension segments, tiling [N, 2N) from the resume cursor.
      var first = RegionIndex.coveredTo(a.rix, 0);
      while (first < 2 * N) {
        let count = Nat.min(SEG, 2 * N - first);
        commitSeg(a, first, count);
        first += count;
      };
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;   // tiled again ⟹ serving
      assert Table.size(a) == Table.size(b);
      // A position that ended up in the base AND the delta would surface here: the two
      // halves are concatenated without dedup, so `count` would exceed the oracle's.
      assert agreeAll(ra, rb);

      // Appends after the extension are delta rows again, above the new frontier.
      for ((acct, amount) in ([(50, 1), (2, 9), (0, 0)] : [(Nat, Nat)]).values()) {
        let row : [(Text, OQL.Value)] = [("acct", #nat acct), ("amount", #nat amount)];
        ignore Table.append(a, row, asRow);
        ignore Table.append(b, row, asRow);
      };
      assert agreeAll(ra, rb);

      // A delete in each half of the extended base, and one in the delta.
      for (p in ([9, N + 17, 2 * N] : [Nat]).values()) { Table.delete(a, p); Table.delete(b, p) };
      assert agreeAll(ra, rb);
    });

    await test("a column reopened round after round stays exact", func() : async () {
      // Each round appends segments to the same directory, which reallocates and
      // free-lists its old block as the count outgrows its capacity — a path a single
      // load barely touches. Every earlier segment must still read, and still take a
      // DEAD bit, after that churn.
      let ROUNDS = 3;
      let a = regionTable();
      var round = 1;
      while (round < ROUNDS) {
        driveReopen(a, "acct");
        let from = round * N;
        let img = Region.new();
        ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, func (r : Nat, c : Nat) : ?Cell.Cell = imgCell(from + r, c)));
        var first = RegionIndex.coveredTo(a.rix, 0);
        assert first == from;
        while (first < from + N) {
          let count = Nat.min(SEG, from + N - first);
          commitSeg(a, first, count);
          first += count;
        };
        round += 1;
      };
      assert Table.appended(a) == ROUNDS * N;
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
      let b = heapRows(ROUNDS * N);
      assert agreeAll(regReg(a), regReg(b));

      // Deletes spread over every round's segments, after all that reallocation.
      for (p in ([1, 2, N + 1, 2 * N + 1, 3 * N - 1] : [Nat]).values()) { Table.delete(a, p); Table.delete(b, p) };
      assert agreeAll(regReg(a), regReg(b));
    });

    await test("a zone map never prunes a row the predicate matches", func() : async () {
      // The footers a zone map prunes on are folded with `Cell.lt`. When that was `<` for
      // floats it was false in both directions against NaN, so a NaN was left out of the
      // footer entirely and `positionsWhere` skipped the whole segment for an open-top range
      // — dropping the very row the predicate matches, since `Predicate.compare` ranks NaN
      // greatest. `prune` must always yield a SUPERSET, so flushing a segment cannot change
      // an answer.
      for (vals in ([[1.0, 2.0, NAN, 3.0], [NAN, 1.0, 2.0], [1.0, NAN]] : [[Float]]).values()) {
        let t = Table.new([("score", #float)], []);
        for (v in vals.values()) ignore Table.append(t, [("score", #float v)], asRow);
        let r = regReg(t);
        for (p in ([?#gt(["score"], #float 1000.0), ?#ge(["score"], #float 1000.0),
                    ?#lt(["score"], #float 0.0), ?#gt(["score"], #float 1.5)] : [?OQL.Predicate.Predicate]).values()) {
          let q = base(p);
          let buffered = Executor.runWith(r, q, unrestricted).rows.size();
          Table.flush(t);
          assert Executor.runWith(r, q, unrestricted).rows.size() == buffered;
        };
      };
    });

    await test("min/max over a #float column with NaN: served equals scanned", func() : async () {
      // The footers are folded with `Cell.lt`, which is false in both directions against
      // NaN: a NaN landing FIRST is never displaced and pins both extremes of its segment
      // to NaN, and a NaN anywhere else is skipped. The scan folds with `Predicate.compare`,
      // where NaN sorts greatest. Serving float extremes from footers therefore answered
      // min = NaN for [NaN, 1, 5, 2] — wrong under every convention, 1.0 being the minimum.
      for (vals in ([[NAN, 1.0, 5.0, 2.0], [1.0, NAN, 5.0, 2.0], [1.0, 5.0, 2.0, NAN]] : [[Float]]).values()) {
        let t = floatTable(vals);
        // Compared through `Predicate.compare`, not `==`: NaN is not IEEE-equal to itself,
        // and this is the order the engine defines, under which NaN equals only NaN.
        assert OQL.Predicate.compare(extreme(t, #min, false), extreme(t, #min, true)) == #equal;
        assert OQL.Predicate.compare(extreme(t, #max, false), extreme(t, #max, true)) == #equal;
      };
      // A float column with no NaN still agrees, so the exclusion did not break the type.
      let clean = floatTable([3.5, 1.25, 9.0]);
      assert extreme(clean, #min, false) == #float 1.25;
      assert extreme(clean, #max, false) == #float 9.0;
    });

    await test("min/max come from the segment footers, and stay exact under deletes", func() : async () {
      // `amount` (r*7 % 100) is not indexed at all, so before footer-served
      // extremes this could only be scanned. min/max must equal a brute-force fold
      // over the live rows at every stage.
      let a = regionTable();
      let ra = regReg(a);
      let AMOUNT = 1;                                  // column index of "amount"
      func isDead(deleted : [Nat], r : Nat) : Bool {
        for (d in deleted.values()) { if (d == r) return true };
        false;
      };
      func liveFold(deleted : [Nat], wantMin : Bool) : Nat {
        var best = if wantMin { 1000 } else { 0 };
        var r = 0;
        while (r < N) {
          if (not isDead(deleted, r)) {
            let v = r * 7 % 100;
            if (if wantMin { v < best } else { v > best }) best := v;
          };
          r += 1;
        };
        best;
      };

      // Stage 1: clean segments — every footer extreme stands, no scan needed.
      assert Table.appended(a) == N;
      assert scalar(ra, minQ("amount"), "min_amount") == #nat(liveFold([], true));
      assert scalar(ra, maxQ("amount"), "max_amount") == #nat(liveFold([], false));
      // The store agrees directly, which is what the planner reads.
      assert Columnar.minOf(a.store, AMOUNT) == ?#nat(Nat64.fromNat(liveFold([], true)));
      assert Columnar.maxOf(a.store, AMOUNT) == ?#nat(Nat64.fromNat(liveFold([], false)));

      // Stage 2: delete the rows that HOLD the extremes. Their segment footers are
      // now stale — a footer cannot be narrowed without looking — so that segment
      // must be rescanned rather than trusted.
      let lo = liveFold([], true);
      let hi = liveFold([], false);
      let dead = List.empty<Nat>();
      var r = 0;
      while (r < N) { let v = r * 7 % 100; if (v == lo or v == hi) dead.add(r); r += 1 };
      let deadArr = dead.toArray();
      for (p in deadArr.values()) { Table.delete(a, p) };
      assert scalar(ra, minQ("amount"), "min_amount") == #nat(liveFold(deadArr, true));
      assert scalar(ra, maxQ("amount"), "max_amount") == #nat(liveFold(deadArr, false));

      // Stage 3: a post-commit append lands in the buffer, which has no footer yet
      // and is always folded in.
      ignore Table.append(a, [("acct", #nat 3), ("amount", #nat 999)], asRow);
      assert scalar(ra, maxQ("amount"), "max_amount") == #nat 999;
    });

    await test("rows deleted while the column is pending are DEAD in the committed base", func() : async () {
      // A delete during the load tombstones the store row but marks no DEAD bit —
      // `onDelete` only marks a READY column. `count` is pure run arithmetic and
      // never consults the store, so without folding those tombstones in at ready
      // the base would report the deleted rows live for good.
      let a = Table.new(COLS, []);
      let img = Region.new();
      ignore Table.loadSegment(a, Image.build(img, [#nat, #nat], N, imgCell));
      commitSeg(a, 0, SEG);                              // pending: SEG < N
      // Inside the committed segment, and inside two not-yet-committed ones. 11 is
      // a null row, so the null run is covered too.
      let dead : [Nat] = [3, 7, 11, SEG + 5, 2 * SEG + 9];
      for (p in dead.values()) { Table.delete(a, p) };
      var first = SEG;
      while (first < N) {
        let count = Nat.min(SEG, N - first);
        commitSeg(a, first, count);
        first += count;
      };
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;

      let b = heapRows(N);
      for (p in dead.values()) { Table.delete(b, p) };
      assert agreeAll(regReg(a), regReg(b));
    });

    await test("rows loaded while the column is pending are covered by the DEAD bitmap", func() : async () {
      // The DEAD bitmap spans the whole base. If it is sized when the FIRST
      // segment commits, it covers only the rows loaded by then, and every base
      // position past that reads (and, on delete, writes) past the allocation —
      // a silent under-fetch with no delete involved, and corruption with one.
      let a = regionTableInterleaved();
      let b = heapRows(2 * N);
      let ra = regReg(a);
      let rb = regReg(b);
      assert Table.appended(a) == 2 * N and Table.appended(b) == 2 * N;
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;   // tiled ⟹ served
      assert agreeAll(ra, rb);

      // A base delete in the tail — the half of the base loaded after the first
      // commit — must land in the bitmap, not on whatever follows it.
      for (p in ([N, N + 1, N + 11, 2 * N - 1] : [Nat]).values()) { Table.delete(a, p); Table.delete(b, p) };
      assert agreeAll(ra, rb);
    });

    await test("a base is probed only with values its own column can hold", func() : async () {
      // The base is keyed by RAW CELL BITS, and #bool true and #nat 1 reduce to
      // the same key. Probing a #bool base with the #nat re-fetches every `true`
      // row a second time, and the executor's residual cannot drop the copies —
      // those rows do satisfy the IN — so `count(*)` doubles.
      let ra = regReg(boolRegionTable());
      let rb = regReg(boolHeapTable());
      let both : OQL.Predicate.Predicate = #in_(["flag"], [#bool true, #nat 1]);
      assert agree(ra, rb, base(?both));
      assert agree(ra, rb, countOf(base(?both)));
      // The other direction of the same aliasing: a #nat probe on a #bool column
      // matches nothing in the heap twin, so the base must contribute nothing.
      assert agree(ra, rb, base(?#eq(["flag"], #nat 1)));
      assert agree(ra, rb, countOf(base(?#eq(["flag"], #nat 1))));
      assert agree(ra, rb, base(?#eq(["flag"], #text "true")));
    });

    await test("a base serves every value its column can hold, whatever kind the probe arrived as", func() : async () {
      // Under-fetch, on the #nat twin: a float denoting exactly the integer a
      // cell holds is `#equal` to it (`Predicate.compare` bridges the numeric
      // kinds), so the heap index serves acct=3 for the probe 3.0 and the base
      // must serve the same rows rather than nothing.
      let rn = regReg(regionTable());
      let rh = regReg(heapTable());
      assert agree(rn, rh, pointQ(#float 3.0));
      assert agree(rn, rh, countOf(pointQ(#float 3.0)));
      assert agree(rn, rh, inQ([#float 3.0, #int 5]));
      assert agree(rn, rh, pointQ(#int 3));
      assert agree(rn, rh, countOf(pointQ(#int 3)));
      // A numeric that no #nat cell can hold still contributes nothing.
      assert agree(rn, rh, pointQ(#float 3.5));
      assert agree(rn, rh, pointQ(#int(-3)));
      assert agree(rn, rh, countOf(pointQ(#float 3.5)));
    });

    await test("a row deleted while buffered is DEAD in a base committed after the flush", func() : async () {
      // A buffered delete clears its slot; the flush then materialises the row as
      // a tombstone. `commitIndex` folds the store's tombstones into the base by
      // reading each deleted row's cells and probing the run its posting sits in
      // — so the flush must carry the row's real cells into the segment. With the
      // cells gone the fold probes the NULL run, sets no DEAD bit, and `count`,
      // being run arithmetic, reports the row live for the life of the index.
      let a = Table.new(COLS, []);
      var r = 0;
      while (r < N) { ignore Table.append(a, rowOf(r), asRow); r += 1 };
      let dead : [Nat] = [3, 11, 2 * SEG + 3];   // acct 3, a null row, acct 3 again
      for (p in dead.values()) { Table.delete(a, p) };
      Table.flush(a);
      var first = 0;
      while (first < N) {
        let count = Nat.min(SEG, N - first);
        commitSeg(a, first, count);
        first += count;
      };
      assert OQL.SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;

      let b = heapRows(N);
      for (p in dead.values()) { Table.delete(b, p) };
      assert Table.size(a) == Table.size(b);
      assert agreeAll(regReg(a), regReg(b));
    });
  };
};
