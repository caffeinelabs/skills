/// The region-resident side of a table's secondary indexes: one aux `Region` per
/// table holding a superblock, an index directory, a free list, and — per indexed
/// column — a LIST of immutable hash SEGMENTS, each with its own DEAD bitmap. This
/// is the BASE half of the `base ∪ delta` split; the DELTA is the ordinary
/// heap `SecondaryIndex`, maintained by `onChange` for writes made after commit.
///
/// SEGMENTED. A column's base is not one monolithic
/// index over every loaded row — which would force the producer to hold the whole
/// ~8 B/row structure in memory — but K segments, each covering a contiguous run
/// `[firstRow, firstRow + rows)` of store positions. The producer builds and
/// uploads one segment at a time, so its peak memory is one segment's worth at any
/// table size. The segments of a column must TILE `[0, appended)` exactly; until
/// they do the column stays PENDING — which no longer means it answers nothing: the
/// segments it has serve `[0, coveredEnd)` and only the rows past that are scanned
/// (see `servingEntry`/`tailStart`), so no gap is ever an under-fetch and no query on
/// a half-loaded column pays for the whole table.
///
/// EXTENSIBLE: a ready column can go back to pending (`reopen`) so a later load is
/// covered by FURTHER segments rather than a re-upload of the whole base.
///
/// The heap never holds anything proportional to the loaded rows: the segments
/// and the DEAD bitmap live entirely in the aux Region (off the GC heap, across
/// upgrades). The heap keeps only a small directory MIRROR — one `Entry` per
/// column, each with its segment list — so serving reads a `List`, not the
/// superblock; the superblock and directory are written to the Region too, which
/// is what keeps it recoverable from bytes alone.
///
/// A loaded row is deleted by setting a bit in DEAD rather than mutating a heap
/// posting list. Each segment carries its OWN bitmap, one bit per posting over its
/// own `rows`, allocated at that segment's commit: nothing here is ever sized by the
/// table's total row count, which is the same reason the base is segmented at all.
/// A run lives inside one segment, so its popcount stays a single contiguous
/// `deadPop` over that segment's bitmap at the run's LOCAL slots.
/// `count(k) = Σ_j runLen_j − popcount(DEAD_j over run_j) + delta`.
///
/// Serving is additive behind the existing `Served` closures: `point`/`count`/
/// `groupCount`/eq-null union the K segments here and the caller unions the delta.
/// The executor and planner are untouched — `kindOf` reports the region index, and
/// a `#hash` base serves point / IN / count / groupCount only (the executor already
/// routes range / min / max to `#ordered` alone).
///
/// Aux region layout:
/// ```
/// superblock 4 KiB
///   0 u32 magic 'OQAX'   4 u16 version   6 u16 entryCount
///   8 u64 freeListHead   16 u64 end
///   64 .. : entries, 64 B each (max 63) — ONE per indexed column
///     0 u8 state   1 u8 kind   2 u8 ncols   3 u8 keyType   4 u16 col   6 u16 segCount
///     16 u64 segDirOff   24 u64 coveredEnd   32 u64 deadCount
///   segDir: segCount × 40 B
///     { firstRow u64 | rows u64 | segOff u64 | segLen u64 | deadOff u64 }
/// ```
/// (`ncols`/`col` carry a single column here; composite region indexes are a later
/// deliverable. `deadCount`/`coveredEnd`/`segDir` are the mutable
/// fields; a segment's own record is immutable once committed.)
import Iter    "mo:core/Iter";
import List    "mo:core/List";
import Nat     "mo:core/Nat";
import Nat64   "mo:core/Nat64";
import Option  "mo:core/Option";
import Region  "mo:core/Region";
import Runtime "mo:core/Runtime";
import Cell    "columnar/Cell";
import HashSegment "columnar/HashSegment";
import SecondaryIndex "SecondaryIndex";

module {

  public type Kind = SecondaryIndex.Kind;

  /// A column's region index as a producer needs to see it. `#building` never completed a
  /// first upload; `#extending` was reopened for a delta or is mid-absorb. Both still need
  /// the run to finish them, so a producer must not decide from readiness alone.
  public type ProducerState = { #none; #ready; #building; #extending };

  let WORD : Nat64 = 8;
  let PAGE : Nat64 = 65536;
  let SUPERBLOCK : Nat64 = 4096;
  let ENTRY : Nat64 = 64;
  let ENTRIES_OFF : Nat64 = 64;
  let MAX_ENTRIES : Nat = 63;
  let SEGREC : Nat64 = 40;          // one segment directory record

  let MAGIC : Nat32 = 0x4F514158;   // "OQAX"
  let VERSION : Nat16 = 2;          // 2: per-segment DEAD bitmap, 40-byte segDir record

  // state byte 1 = pending: the segments do not tile [0, appended) — still being
  // loaded, or ready and REOPENED for extension by a later load. 2 = ready.
  let STATE_PENDING : Nat8 = 1;
  let STATE_READY : Nat8 = 2;
  // Pending BECAUSE it was reopened, as opposed to pending because it has never been
  // complete. `coveredEnd == appended` only compares COUNTS — an append and a segment row
  // each add one — so a row that entered any other way shifts every later position against
  // its posting while the arithmetic still balances, and the column flips ready over a base
  // describing the wrong rows. Only provenance can tell the two apart, so while a column
  // sits here `Table.append` is refused and a segment is the only way a position can enter.
  //
  // A FIRST load needs the same property and gets it elsewhere: `Table.loadSegment` refuses
  // a table holding any position that arrived by append, so the file's rows keep landing at
  // the positions the producer names them with. Both guards say the same thing — a table
  // being loaded takes rows from one source only — they just fire at different ends.
  let STATE_REOPENED : Nat8 = 3;
  // Mid-ABSORB: the canister is indexing rows it appended itself, a chunk per message,
  // and the gap is not closed yet. Distinct from plain PENDING, which means an upload
  // that has never completed — an absorb must be able to continue, and a first upload
  // must never be absorbed into (its gap is file rows the producer still owes).
  let STATE_ABSORBING : Nat8 = 4;
  let KIND_HASH : Nat8 = 0;

  /// One base segment: the hash-segment bytes at `segOff` covering the store
  /// positions `[firstRow, firstRow + rows)`, plus `deadOff`, its own DEAD bitmap
  /// over `rows` bits addressed by LOCAL posting slot. Immutable once committed —
  /// the bitmap's CONTENTS change, its location and size do not.
  public type Segment = {
    firstRow : Nat;
    rows : Nat;
    segOff : Nat64;
    segLen : Nat64;
    deadOff : Nat64;
  };

  /// One indexed column's directory descriptor — the heap mirror of a superblock
  /// entry, holding the column's ordered segment list — each segment owning its own
  /// DEAD bitmap. `var` fields are the mutable ones (segments accrete at commit,
  /// `deadCount` grows over deletes); the column identity is fixed at first commit. Pure data, so it persists under enhanced orthogonal persistence
  /// alongside the table.
  public type Entry = {
    colIdx : Nat;
    kind : Kind;
    keyType : Cell.ColType;
    slot : Nat;                    // directory slot index (0..<63), its byte home
    segments : List.List<Segment>;
    var coveredEnd : Nat;          // contiguous coverage end: segments tile [0, coveredEnd)
    var state : Nat8;
    var deadCount : Nat;           // DEAD bits set across every segment (for stats)
    var segDirOff : Nat64;         // region array persisting `segments` (0 until first commit)
    var segDirCap : Nat;           // records the segDir block can hold
  };

  // An in-flight segment upload: one at a time per table. Cleared at commit.
  type Staging = {
    colIdx : Nat;
    kind : Kind;
    keyType : Cell.ColType;
    firstRow : Nat;
    segOff : Nat64;
    segLen : Nat64;
    var covered : Nat64;                  // bytes written, in any order
    received : List.List<(Nat64, Nat64)>; // (offset, len) per chunk, to refuse a re-send
  };

  /// A table's aux region and its directory mirror. Pure data.
  public type State = {
    region : Region.Region;
    entries : List.List<Entry>;
    var end : Nat64;               // next unallocated byte (mirrors the superblock)
    var freeListHead : Nat64;
    var staging : ?Staging;
  };

  /// A fresh, empty aux region. The Region is NOT grown until the first segment
  /// is committed, so a table that never uploads a region index pays no stable
  /// pages for one.
  public func empty() : State = {
    region = Region.new();
    entries = List.empty<Entry>();
    var end = SUPERBLOCK;
    var freeListHead = 0;
    var staging = null;
  };

  // ── allocation ─────────────────────────────────────────────────────────────

  func ensureBytes(st : State, bytes : Nat64) {
    let have = st.region.size() * PAGE;
    if (have < bytes) {
      if (st.region.grow((bytes - have + PAGE - 1) / PAGE) == 0xFFFF_FFFF_FFFF_FFFF) {
        Runtime.trap("RegionIndex: aux Region is full — raise --max-stable-pages in the consuming project's [moc] args");
      };
    };
  };

  func align8(n : Nat64) : Nat64 = (n + 7) / 8 * 8;

  /// Reserve `len` bytes: first a free-list block large enough (first fit,
  /// splitting any remainder back onto the list), else fresh space at `end`. A
  /// free block's first 16 bytes are `next | len`. Regions never shrink, so drop
  /// and compaction return segments here for reuse (both later deliverables), and
  /// the segment directory reallocates through it as a column accretes segments.
  func alloc(st : State, len0 : Nat) : Nat64 {
    // Never hand out fewer than 16 bytes: `free` writes a `next | len` header into
    // whatever it reclaims, so an 8-byte block — a one-word DEAD bitmap, or a
    // segment length a caller declared small — would corrupt its neighbour when
    // returned. `free` floors the recorded length the same way.
    let len = do { let a = align8((len0).toNat64()); if (a < 16) (16 : Nat64) else a };
    var prev : Nat64 = 0;
    var cur = st.freeListHead;
    while (cur != 0) {
      let next = st.region.loadNat64(cur);
      let blockLen = st.region.loadNat64(cur + WORD);
      if (blockLen >= len) {
        // Unlink, then split the remainder if it can hold a free header.
        if (prev == 0) st.freeListHead := next else st.region.storeNat64(prev, next);
        if (blockLen >= len + 16) free(st, cur + len, Nat64.toNat(blockLen - len));
        writeSuperblock(st);
        return cur;
      };
      prev := cur;
      cur := next;
    };
    let off = st.end;
    st.end += len;
    ensureBytes(st, st.end);
    writeSuperblock(st);
    off;
  };

  /// Return a block to the free list (drop / compaction, and segment-directory
  /// reallocation). A free block's first 16 bytes are `next | len`.
  func free(st : State, off : Nat64, len0 : Nat) {
    let len = do { let a = align8((len0).toNat64()); if (a < 16) (16 : Nat64) else a };
    st.region.storeNat64(off, st.freeListHead);
    st.region.storeNat64(off + WORD, len);
    st.freeListHead := off;
    writeSuperblock(st);
  };

  // ── superblock / directory persistence ──────────────────────────────────────

  // Write the superblock header and every live directory entry to the Region, so
  // the aux region is self-describing (the heap mirror is the fast path; these
  // bytes are the durable copy a recover-from-bytes path rests on).
  func writeSuperblock(st : State) {
    ensureBytes(st, SUPERBLOCK);
    st.region.storeNat32(0, MAGIC);
    st.region.storeNat16(4, VERSION);
    st.region.storeNat16(6, (st.entries.size()).toNat16());
    st.region.storeNat64(8, st.freeListHead);
    st.region.storeNat64(16, st.end);
  };

  func writeEntry(st : State, e : Entry) {
    let b = ENTRIES_OFF + (e.slot).toNat64() * ENTRY;
    st.region.storeNat8(b, e.state);
    st.region.storeNat8(b + 1, kindByte(e.kind));
    st.region.storeNat8(b + 2, 1);                        // ncols
    st.region.storeNat8(b + 3, keyTypeByte(e.keyType));
    st.region.storeNat16(b + 4, (e.colIdx).toNat16());    // col
    st.region.storeNat16(b + 6, (e.segments.size()).toNat16());   // segCount
    st.region.storeNat64(b + 16, e.segDirOff);
    st.region.storeNat64(b + 24, (e.coveredEnd).toNat64());
    st.region.storeNat64(b + 32, (e.deadCount).toNat64());
  };

  // Persist the column's segment list to a region array, reallocating the block
  // when the count outgrows its capacity (K is small, so growth is rare). The old
  // block returns to the free list. Keeps the aux region recoverable from bytes.
  func writeSegDir(st : State, e : Entry) {
    let count = e.segments.size();
    if (count > e.segDirCap) {
      let newCap = if (e.segDirCap == 0) 4 else e.segDirCap * 2;
      let cap = if (newCap >= count) newCap else count;
      let off = alloc(st, cap * SEGREC.toNat());
      if (e.segDirOff != 0) free(st, e.segDirOff, e.segDirCap * SEGREC.toNat());
      e.segDirOff := off;
      e.segDirCap := cap;
    };
    var i : Nat64 = 0;
    for (s in e.segments.values()) {
      let r = e.segDirOff + i * SEGREC;
      st.region.storeNat64(r, (s.firstRow).toNat64());
      st.region.storeNat64(r + 8, (s.rows).toNat64());
      st.region.storeNat64(r + 16, s.segOff);
      st.region.storeNat64(r + 24, s.segLen);
      st.region.storeNat64(r + 32, s.deadOff);
      i += 1;
    };
  };

  func kindByte(k : Kind) : Nat8 = switch k { case (#hash) KIND_HASH; case (#ordered) 1 };
  func keyTypeByte(t : Cell.ColType) : Nat8 = switch t { case (#nat) 0; case (#int) 1; case (#float) 2; case (#bool) 3; case (#text) 4; case (#bytes _) Runtime.trap("RegionIndex: a #bytes column cannot be indexed") };

  // The heap directory entry for `colIdx`, or null.
  func entryOf(st : State, colIdx : Nat) : ?Entry {
    for (e in st.entries.values()) { if (e.colIdx == colIdx) return ?e };
    null;
  };

  // ── upload + commit ─────────────────────────────────────────────────────────

  /// Accept one ordered chunk of a segment upload covering `[firstRow, …)`. The
  /// first chunk (`expectOffset == 0`) allocates the segment and begins staging;
  /// every chunk must arrive at the offset the table has filled so far (the same
  /// expect-offset idempotency as `putSegment`), so a retried message traps rather
  /// than duplicating bytes. Returns the bytes filled so far.
  public func putChunk(st : State, colIdx : Nat, kind : Kind, keyType : Cell.ColType, firstRow : Nat, segLen : Nat, expectOffset : Nat, chunk : Blob) : Nat {
    let stg = switch (st.staging) {
      case null {
        let off = alloc(st, segLen);
        // The whole segment is reserved now, so a chunk may be written at any offset
        // within it — which is what lets chunks go out on the wire concurrently.
        ensureBytes(st, off + (segLen).toNat64());
        let s : Staging = {
          colIdx; kind; keyType; firstRow; segOff = off; segLen = (segLen).toNat64();
          var covered = 0; received = List.empty<(Nat64, Nat64)>();
        };
        st.staging := ?s;
        s;
      };
      case (?s) {
        if (s.colIdx != colIdx or s.segLen != (segLen).toNat64() or s.firstRow != firstRow)
          Runtime.trap("RegionIndex.putChunk: a different upload is already in progress");
        s;
      };
    };
    // Chunks may arrive in ANY order — the segment's bytes are already reserved, so a
    // chunk is placed at the offset it names. What must still hold is that they cover
    // the segment exactly once: an overlapping chunk is a re-send or a producer bug, and
    // accepting it would double-count `covered` and leave a hole elsewhere, so commit
    // would pass on a segment with unwritten bytes.
    let at = (expectOffset).toNat64();
    let len = (chunk.size()).toNat64();
    if (at + len > stg.segLen)
      Runtime.trap("RegionIndex.putChunk: chunk at " # expectOffset.toText() # " of " # chunk.size().toText() # " bytes runs past the declared segment length " # stg.segLen.toText());
    for ((o, l) in stg.received.values()) {
      if (at < o + l and o < at + len)
        Runtime.trap("RegionIndex.putChunk: chunk at " # expectOffset.toText() # " overlaps bytes already written at " # o.toText() # " — send each chunk once");
    };
    st.region.storeBlob(stg.segOff + at, chunk);
    stg.received.add((at, len));
    stg.covered += len;
    Nat64.toNat(at + len);
  };

  /// Discard the in-flight upload, returning its block to the free list. Without
  /// this a partial upload wedges the column: `putChunk` refuses a different
  /// segment while one is staged, and `commit` refuses a partially filled one, so a
  /// producer that died mid-segment could neither finish nor restart and the column
  /// would stay pending for good. Returns whether there was an upload to discard.
  /// Discard `colIdx`'s committed BASE entirely: every segment's bytes and DEAD bitmap
  /// back on the free list, the entry reset to covering nothing. The column keeps its
  /// directory slot — slots are byte homes and shifting them would rewrite every entry —
  /// but an entry covering nothing serves nothing (`servingEntry` needs coverage), so the
  /// column is simply unindexed again and queries scan.
  ///
  /// This is the recovery path for a base that cannot be finished. A first upload that
  /// committed some segments and was then overtaken by ordinary writes is the case: the
  /// file can no longer describe the positions its remaining segments would claim, so the
  /// off-chain path is closed, and the on-chain build needs the column clear. Without this
  /// such a table had NO way back — `abortUpload` drops staging, never a committed segment.
  ///
  /// Returns false when there is nothing to drop — no entry, OR an entry already dropped.
  /// The second half matters: this is `true` meaning "I removed an index", and the caller
  /// removes the heap decl on the strength of it. A dropped entry keeps its slot, so
  /// answering `true` again would make a retried drop delete whatever index was built to
  /// REPLACE the one dropped — the very recovery this exists to enable.
  ///
  /// Any in-flight staging is the caller's to abort first; this touches only what is
  /// committed.
  public func dropBase(st : State, colIdx : Nat) : Bool =
    switch (entryOf(st, colIdx)) {
      case null false;
      case (?e) {
        if (e.coveredEnd == 0) return false;   // already dropped: not ours to report again
        for (seg in e.segments.values()) {
          free(st, seg.segOff, seg.segLen.toNat());
          free(st, seg.deadOff, (seg.rows + 63) / 64 * 8);
        };
        if (e.segDirCap > 0) free(st, e.segDirOff, e.segDirCap * SEGREC.toNat());
        e.segments.clear();
        e.coveredEnd := 0;
        e.deadCount := 0;
        e.state := STATE_PENDING;
        e.segDirOff := 0;
        e.segDirCap := 0;
        writeEntry(st, e);
        writeSuperblock(st);
        true;
      };
    };

  /// The column an in-flight segment upload belongs to, if any. Staging is per TABLE — one
  /// upload at a time — so a caller acting on one column must check before aborting, or it
  /// discards another column's bytes and leaves that commit to fail.
  public func stagingCol(st : State) : ?Nat =
    switch (st.staging) { case (?s) ?s.colIdx; case null null };

  public func abortUpload(st : State) : Bool =
    switch (st.staging) {
      case null false;
      case (?s) { free(st, s.segOff, s.segLen.toNat()); st.staging := null; true };
    };

  /// The result of committing one segment: its row count, the column's kind/key
  /// type, and whether the column is now fully tiled (`ready`) so the caller can
  /// declare and mark the heap delta.
  public type Committed = { rows : Nat; keyType : Cell.ColType; kind : Kind; ready : Bool };

  /// Append the staged segment to `colIdx`'s base and, if the segments now tile
  /// `[0, appended)`, flip the column ready. `appended` is the table's position
  /// cursor.
  ///
  /// Coverage guard, the generalisation of the old
  /// `segment.rows == appended`: the union of a column's segment ranges must equal
  /// `[0, appended)` with no gap or overlap. Enforced incrementally — segments
  /// arrive in ascending order, each starting exactly where the last ended
  /// (`firstRow == coveredEnd`, so the first starts at 0) and none reaching past
  /// `appended`. The column serves only once coverage reaches `appended`; a run
  /// appended between load and commit leaves the tiling short, so the column stays
  /// pending, serving the prefix it covers and scanning the rest, rather than
  /// under-fetching.
  ///
  /// Commit does not re-derive the postings — that pass is O(rows) and does not fit
  /// one message at scale. What it does check is bounded per segment: the whole
  /// header via `HashSegment.checkHeader` (magic, version, and every section offset
  /// the reader will follow aligned, ordered, and inside the uploaded bytes), plus
  /// the coverage arithmetic above. A header that steered the reader outside the
  /// segment is therefore rejected here, not trusted. `HashSegment.validate` adds
  /// the O(rows) posting and tiling audit off-line.
  public func commit(st : State, colIdx : Nat, appended : Nat) : Committed {
    let ?stg = st.staging else Runtime.trap("RegionIndex.commit: no upload to commit");
    if (stg.colIdx != colIdx) Runtime.trap("RegionIndex.commit: staged upload is for a different column");
    if (stg.covered != stg.segLen) Runtime.trap("RegionIndex.commit: segment is only partially uploaded (" # stg.covered.toText() # " of " # stg.segLen.toText() # " bytes)");
    switch (stg.kind) { case (#hash) {}; case (#ordered) Runtime.trap("RegionIndex.commit: #ordered region index is deferred") }; // deferred
    // A #hash key has no float encoding — the reader would trap on the first probe
    // — so refuse the column here rather than after it is serving.
    switch (stg.keyType) { case (#float) Runtime.trap("RegionIndex.commit: #hash over a #float column is deferred"); case _ {} };

    let h = switch (HashSegment.checkHeader(st.region, stg.segOff, stg.segLen)) {
      case (#ok h) h;
      case (#err e) Runtime.trap("RegionIndex.commit: malformed segment header — " # e);
    };
    let segRows = h.rows;

    // Find or create the column's directory entry.
    let e = switch (entryOf(st, colIdx)) {
      case (?e) {
        if (e.state == STATE_READY) Runtime.trap("RegionIndex.commit: column " # colIdx.toText() # " is already fully committed");
        e;
      };
      case null {
        if (st.entries.size() >= MAX_ENTRIES) Runtime.trap("RegionIndex.commit: the aux directory is full (63 indexed columns)");
        let ne : Entry = {
          colIdx; kind = stg.kind; keyType = stg.keyType; slot = st.entries.size();
          segments = List.empty<Segment>();
          var coveredEnd = 0; var state = STATE_PENDING;
          var deadCount = 0;
          var segDirOff = 0; var segDirCap = 0;
        };
        st.entries.add(ne);
        ne;
      };
    };

    // Coverage arithmetic: in-order, no gap/overlap, no overshoot past `appended`.
    if (stg.firstRow != e.coveredEnd)
      Runtime.trap("RegionIndex.commit: segment starts at " # stg.firstRow.toText() # " but the column is covered to " # e.coveredEnd.toText() # " — segments must tile [0, appended) with no gap or overlap");
    if (stg.firstRow + segRows > appended)
      Runtime.trap("RegionIndex.commit: segment covers rows past the table's appended " # appended.toText() # " (coverage guard)");

    // This segment's own DEAD bitmap: `segRows` bits, addressed by local posting
    // slot. Sized by the SEGMENT, never by the table — a whole-base bitmap would be
    // one allocation proportional to total rows (and one zeroing loop proportional
    // to it, inside a single message), which is exactly what segmenting the base
    // exists to avoid. It also removes any dependence on `appended`: rows loaded
    // between commits cannot leave a bitmap too small for the base it covers.
    let deadWords = (segRows + 63) / 64;
    let deadOff = alloc(st, deadWords * 8);
    var w = 0;
    while (w < deadWords) { st.region.storeNat64(deadOff + (w).toNat64() * WORD, 0); w += 1 };

    e.segments.add({ firstRow = stg.firstRow; rows = segRows; segOff = stg.segOff; segLen = stg.segLen; deadOff });
    e.coveredEnd += segRows;
    let ready = e.coveredEnd == appended;
    if (ready) e.state := STATE_READY;

    writeSegDir(st, e);
    writeEntry(st, e);
    writeSuperblock(st);
    st.staging := null;
    { rows = segRows; keyType = stg.keyType; kind = stg.kind; ready };
  };

  // ── directory lookup ────────────────────────────────────────────────────────

  /// Whether any column is mid-extension, i.e. reopened and not yet complete. A position
  /// that entered while one is would leave that base describing the wrong rows, so the
  /// caller must refuse anything but a segment load until this is false.
  public func anyReopened(st : State) : Bool {
    for (e in st.entries.values()) { if (e.state == STATE_REOPENED or e.state == STATE_ABSORBING) return true };
    false;
  };

  /// The READY region index on `colIdx`, or null. Serving gates on this: a column
  /// whose segments do not yet tile `[0, appended)` is invisible, so queries scan.
  public func readyEntry(st : State, colIdx : Nat) : ?Entry {
    for (e in st.entries.values()) { if (e.colIdx == colIdx and e.state == STATE_READY) return ?e };
    null;
  };

  /// How far `colIdx`'s committed segments tile from row 0: they cover
  /// `[0, coveredTo)`, so the next segment must start exactly here. 0 for a column
  /// with no committed segment. Unlike `readyEntry` this answers for a PENDING
  /// column too — that is the point: it is the producer's resume cursor after an
  /// interrupted upload, the index-side counterpart of the table's position cursor.
  public func coveredTo(st : State, colIdx : Nat) : Nat =
    switch (entryOf(st, colIdx)) { case (?e) e.coveredEnd; case null 0 };

  /// Put a READY column back to PENDING **without** the `coveredEnd == appended`
  /// precondition, so the caller can commit a segment over the rows the base does not
  /// cover. That is the only legitimate use: a ready column whose table has since taken
  /// ordinary appends, where the gap is real rows that no producer can supply — they
  /// were never in a file. The caller builds that segment from the STORE and commits
  /// it, which closes the gap and satisfies `reopen`.
  ///
  /// Unlike `reopen` this leaves the column plain PENDING, not REOPENED: the caller is
  /// mid-absorb and about to commit, not handing control to a producer. Returns the
  /// coverage end the absorbed segment must start at, or null when the column is not
  /// ready or has no gap.
  public func beginAbsorb(st : State, colIdx : Nat, appended : Nat) : ?Nat =
    switch (entryOf(st, colIdx)) {
      case (?e) {
        // READY starts an absorb; ABSORBING CONTINUES one. Accepting only READY meant the
        // first chunk left the entry non-ready and every later call answered "nothing to
        // do", wedging any gap larger than one chunk. Plain PENDING is still refused: that
        // is an upload that never finished, and its gap is file rows the producer owes.
        if (e.coveredEnd >= appended) null
        else if (e.state == STATE_READY or e.state == STATE_ABSORBING) {
          e.state := STATE_ABSORBING; writeEntry(st, e); ?e.coveredEnd;
        } else null;
      };
      case null null;
    };

  /// Reopen a READY column for EXTENSION — the only READY → PENDING transition in
  /// this module, and the whole of the delta-load mechanism on this side. The entry
  /// keeps every segment, its `coveredEnd`, and every DEAD bit; only `state` moves.
  /// The column therefore stops serving (`readyEntry`/`kindOf` go null, so queries
  /// scan), `commit` stops refusing it, and the next segment must start at
  /// `coveredEnd` — exactly the first-load rule, resumed at N instead of 0.
  ///
  /// Returns false, mutating nothing, when there is no entry or it is already
  /// pending: a retried ingress message is a no-op rather than a trap.
  ///
  /// Traps unless `coveredEnd == appended`. A ready column's base covers every
  /// position as of the flip, so the rows between `coveredEnd` and `appended` are
  /// ones APPENDED since, and those live in the heap delta. Extending the base over
  /// them would put a position in the base AND the delta, and the two halves are
  /// concatenated without dedup — the row would be returned twice by `point` and
  /// counted twice by `count`, and no residual filter can drop the copy because it
  /// does satisfy the predicate. Loud refusal instead: a delta upload is for a table
  /// whose rows all arrived as segment images.
  public func reopen(st : State, colIdx : Nat, appended : Nat) : Bool {
    switch (entryOf(st, colIdx)) {
      case null false;
      case (?e) {
        if (e.state != STATE_READY) return false;
        if (e.coveredEnd != appended) Runtime.trap(
          "RegionIndex.reopen: column " # colIdx.toText() # "'s base covers rows up to "
          # e.coveredEnd.toText() # " but the table has appended " # appended.toText()
          # " — the rows in between are in the heap delta, and an extended base would cover them too");
        e.state := STATE_REOPENED;
        writeEntry(st, e);
        true;
      };
    };
  };

  /// Whether `colIdx`'s base is COMPLETE — it covered every position when it was
  /// committed. Distinct from `coveredEnd == appended`, which stops being true the moment
  /// the table takes an ordinary write, and which a producer would otherwise read as "the
  /// index is unfinished" and skip the reopen it in fact needs.
  public func isReady(st : State, colIdx : Nat) : Bool =
    switch (entryOf(st, colIdx)) { case (?e) e.state == STATE_READY; case null false };

  /// Whether `colIdx` is mid-ABSORB — the canister is indexing its own appended rows and
  /// the caller must keep driving. Producer segments are refused meanwhile.
  public func isAbsorbing(st : State, colIdx : Nat) : Bool =
    switch (entryOf(st, colIdx)) { case (?e) e.state == STATE_ABSORBING; case null false };

  /// What a producer needs to know about `colIdx`'s region index in one answer.
  /// `#building` is a first upload that never completed, `#extending` one reopened for a
  /// delta (or mid-absorb). Both still need this run to finish them, which is why a
  /// producer must not decide from readiness alone.
  public func stateOf(st : State, colIdx : Nat) : ProducerState =
    switch (entryOf(st, colIdx)) {
      case null #none;
      case (?e) {
        if (e.coveredEnd == 0) #none            // a dropped base: the slot remains, the index does not
        else if (e.state == STATE_READY) #ready
        else if (e.state == STATE_REOPENED or e.state == STATE_ABSORBING) #extending
        else #building;
      };
    };

  /// Whether `colIdx` has a region base at all, in any state. The test for "would a
  /// second index over this column double-count", which `readyEntry` cannot answer: a
  /// base mid-upload has no heap decl to collide with and still serves its prefix.
  public func hasEntry(st : State, colIdx : Nat) : Bool =
    Option.isSome(entryOf(st, colIdx));

  /// The entry whose base can answer for `colIdx` — ready or NOT. The base tiles
  /// `[0, coveredEnd)` and its postings are correct over that prefix in every state:
  /// a segment is only ever appended at the frontier, and nothing rewrites one. Ready
  /// is just the case where `coveredEnd == appended` and the prefix is everything.
  ///
  /// So a column mid-upload, or reopened for an extension, can serve that prefix and
  /// leave `[coveredEnd, appended)` to a scan — cost proportional to the UNCOVERED
  /// TAIL rather than to the table. `readyEntry` remains the gate for anything that
  /// needs the base to cover every row; this is the gate for anything that can take
  /// a prefix and make up the difference.
  ///
  /// Null when the column has no base at all, which is also when `coveredEnd` is 0
  /// and the "prefix" would be empty — a caller would scan everything either way.
  public func servingEntry(st : State, colIdx : Nat) : ?Entry =
    switch (entryOf(st, colIdx)) {
      case (?e) { if (e.coveredEnd > 0) ?e else null };
      case null null;
    };

  /// `kindOf` for the planner: the region index's kind on `colIdx`, or null. Gated on
  /// `servingEntry`, so a column mid-upload still advertises its index — the point
  /// path answers it from the base plus a tail scan, which is never worse than the
  /// full scan the planner would otherwise pick, and is far better once the base
  /// covers most of the table.
  public func kindOf(st : State, colIdx : Nat) : ?Kind =
    switch (servingEntry(st, colIdx)) { case (?e) ?e.kind; case null null };

  /// Where the UNCOVERED tail begins for `e`, given the table has appended `appended`
  /// rows — the first position the caller has to scan for itself.
  ///
  /// For a READY column this is `appended`, i.e. the tail is EMPTY. Not because the
  /// base covers every row — appends since the commit are past `coveredEnd` — but
  /// because a ready column HAS a decl, so those rows are in the heap delta and the
  /// caller unions that in already. Scanning them too would return each one twice, and
  /// no residual filter could drop the copy: it genuinely matches.
  ///
  /// For a pending or reopened column there is no decl and so no delta, and the rows
  /// past `coveredEnd` are in NEITHER half. That range is the tail, and the caller
  /// must scan it or answer short.
  ///
  /// So exactly one of the two mechanisms owns any given position, in either state.
  public func tailStart(e : Entry, appended : Nat) : Nat =
    if (e.state == STATE_READY) appended else e.coveredEnd;

  // ── DEAD bitmap ─────────────────────────────────────────────────────────────

  func deadBit(st : State, deadOff : Nat64, slot : Nat) : Bool =
    (st.region.loadNat64(deadOff + (slot / 64).toNat64() * WORD) >> (slot % 64).toNat64()) & 1 == 1;

  // Set DEAD bit `slot`; returns true if it was newly set (so the caller counts
  // it once). Idempotent under a repeated delete.
  func setDead(st : State, deadOff : Nat64, slot : Nat) : Bool {
    let off = deadOff + (slot / 64).toNat64() * WORD;
    let word = st.region.loadNat64(off);
    let bit : Nat64 = (1 : Nat64) << (slot % 64).toNat64();
    if (word & bit == bit) return false;
    st.region.storeNat64(off, word | bit);
    true;
  };

  // Set bits in `[start, start+len)` counted, across whole/partial words.
  func deadPop(st : State, deadOff : Nat64, start : Nat, len : Nat) : Nat {
    if (len == 0) return 0;
    var count = 0;
    let endExcl = start + len;
    var i = start;
    while (i < endExcl) {
      let w = i / 64;
      let wordStart = w * 64;
      let lo = if (i > wordStart) i - wordStart else 0;
      let hiExcl = Nat.min(64, endExcl - wordStart);
      let width = hiExcl - lo;
      let mask : Nat64 = if (width == 64) 0xFFFF_FFFF_FFFF_FFFF
                         else (((1 : Nat64) << (width).toNat64()) - 1) << (lo).toNat64();
      let word = st.region.loadNat64(deadOff + (w).toNat64() * WORD);
      count += (Nat64.bitcountNonZero(word & mask)).toNat();
      i := wordStart + hiExcl;
    };
    count;
  };

  // Exact live count through `limit`; stop with the `limit + 1` sentinel once
  // enough live bits have been seen. Unlike `len - deadPop(...)`, this does not
  // traverse a many-million-slot run merely to prove it is larger than a small
  // competing plan.
  func liveCountUpTo(st : State, deadOff : Nat64, start : Nat, len : Nat, limit : Nat) : Nat {
    if (len == 0) return 0;
    var live = 0;
    let endExcl = start + len;
    var i = start;
    while (i < endExcl) {
      let w = i / 64;
      let wordStart = w * 64;
      let lo = if (i > wordStart) i - wordStart else 0;
      let hiExcl = Nat.min(64, endExcl - wordStart);
      let width = hiExcl - lo;
      let mask : Nat64 = if (width == 64) 0xFFFF_FFFF_FFFF_FFFF
                         else (((1 : Nat64) << (width).toNat64()) - 1) << (lo).toNat64();
      let word = st.region.loadNat64(deadOff + (w).toNat64() * WORD);
      live += width - (Nat64.bitcountNonZero(word & mask)).toNat();
      if (live > limit) return limit + 1;
      i := wordStart + hiExcl;
    };
    live;
  };

  // The postings slot of `pos` within an ascending run, by binary search.
  func slotOfPosition(st : State, h : HashSegment.Header, start : Nat, len : Nat, pos : Nat) : ?Nat {
    var lo = start;
    var hi = start + len;
    while (lo < hi) {
      let mid = lo + (hi - lo) / 2;
      let p = HashSegment.positionAt(st.region, h, mid);
      if (p == pos) return ?mid;
      if (p < pos) lo := mid + 1 else hi := mid;
    };
    null;
  };

  // The segment covering base position `pos`, or null (a delta position).
  func segmentOf(e : Entry, pos : Nat) : ?Segment {
    for (s in e.segments.values()) { if (pos >= s.firstRow and pos < s.firstRow + s.rows) return ?s };
    null;
  };

  /// A base delete: for every index, if `pos` is a base position, mark its DEAD bit.
  /// `cells[e.colIdx]` is the deleted row's cell for the indexed column (null → the
  /// null run). Called from `Table.delete` before the store tombstone. The DEAD bit is
  /// the run's LOCAL slot in the owning segment's own bitmap.
  ///
  /// `pos < coveredEnd` is the whole test — the column's STATE is not part of it. What
  /// matters is that a committed segment owns the position, and that is true of a
  /// pending or reopened column's prefix exactly as it is of a ready one's. Gating on
  /// READY as well used to be harmless, because a non-ready column served nothing and
  /// its base was never read; now that the prefix answers queries, a delete it did not
  /// record is a row the base keeps counting.
  ///
  /// Positions at or past `coveredEnd` are still left to the tombstone fold in
  /// `Table.commitIndex`: no segment owns them yet, and the one that eventually does
  /// arrives with a clean bitmap. `setDead` reports whether it flipped the bit, so a
  /// position marked here and folded again later is counted once.
  public func onDelete(st : State, pos : Nat, cells : [?Cell.Cell]) {
    for (e in st.entries.values()) {
      if (pos < e.coveredEnd) {
        switch (segmentOf(e, pos)) {
          case null {};   // covered range but no segment owns it — impossible once tiled
          case (?s) {
            let h = HashSegment.readHeader(st.region, s.segOff);
            let run = switch (HashSegment.keyOf(cells[e.colIdx])) {
              case null ?(h.nullStart, h.nullLen);
              case (?k) HashSegment.probe(st.region, h, k);
            };
            switch run {
              case (?(start, len)) switch (slotOfPosition(st, h, start, len, pos)) {
                case (?slot) if (setDead(st, s.deadOff, slot)) { e.deadCount += 1; writeEntry(st, e) };
                case null {};   // position not in the run — a producer under-fetch, the audit's job
              };
              case null {};     // key absent from the base — likewise a content fault, not ours to force
            };
          };
        };
      };
    };
  };

  // ── serving (base half of the merge, K-way over the segments) ─────────────────

  /// Base positions for `key` (null → the null run), skipping DEAD slots, unioned
  /// across the column's segments. A lazy superset — the caller unions the delta
  /// and its row reader drops tombstones. Positions are absolute, and segments
  /// cover disjoint position ranges, so concatenation is the union.
  public func point(st : State, e : Entry, key : ?HashSegment.Key) : Iter.Iter<Nat> =
    e.segments.values().flatMap<Segment, Nat>(func (s : Segment) : Iter.Iter<Nat> {
      let h = HashSegment.readHeader(st.region, s.segOff);
      let run = switch key { case null ?(h.nullStart, h.nullLen); case (?k) HashSegment.probe(st.region, h, k) };
      switch run {
        case null Iter.empty<Nat>();
        case (?(start, len)) {
          var i = start;
          let endExcl = start + len;
          {
            next = func () : ?Nat {
              while (i < endExcl) {
                let slot = i;
                i += 1;
                if (not deadBit(st, s.deadOff, slot)) return ?HashSegment.positionAt(st.region, h, slot);
              };
              null;
            };
          };
        };
      };
    });

  /// Exact live count for `key` in the base: `Σ_j runLen_j − popcount(DEAD over
  /// run_j)` across the segments.
  public func count(st : State, e : Entry, key : ?HashSegment.Key) : Nat {
    var total = 0;
    for (s in e.segments.values()) {
      let h = HashSegment.readHeader(st.region, s.segOff);
      let run = switch key { case null ?(h.nullStart, h.nullLen); case (?k) HashSegment.probe(st.region, h, k) };
      switch run {
        case null {};
        case (?(start, len)) total += len - deadPop(st, s.deadOff, start, len);
      };
    };
    total;
  };

  /// Count as above, but stop as soon as the result is known to exceed
  /// `limit`. The returned sentinel is `limit + 1`, not a partial estimate, so
  /// callers can make an exact less-than-or-equal planning decision while a
  /// hot posting pays for only its first segment(s).
  public func countUpTo(st : State, e : Entry, key : ?HashSegment.Key, limit : Nat) : Nat {
    var total = 0;
    for (s in e.segments.values()) {
      let h = HashSegment.readHeader(st.region, s.segOff);
      let run = switch key { case null ?(h.nullStart, h.nullLen); case (?k) HashSegment.probe(st.region, h, k) };
      switch run {
        case null {};
        case (?(start, len)) {
          total += liveCountUpTo(st, s.deadOff, start, len, limit - total);
          if (total > limit) return limit + 1;
        };
      };
    };
    total;
  };

  /// The base's per-value live histogram across all segments — for each segment,
  /// its null group (if any live) then one entry per distinct key with a positive
  /// live count. A key or the null group appears once PER SEGMENT it occurs in;
  /// `null` marks the null group. The caller folds these into a value→count map,
  /// so a key spread over segments sums correctly and the delta merges in.
  public func groupCounts(st : State, e : Entry) : Iter.Iter<(?Cell.Cell, Nat)> =
    e.segments.values().flatMap<Segment, (?Cell.Cell, Nat)>(func (s : Segment) : Iter.Iter<(?Cell.Cell, Nat)> {
      let h = HashSegment.readHeader(st.region, s.segOff);
      var phase = 0;   // 0: null group, 1..distinct: key dir
      var idx = 0;
      {
        next = func () : ?(?Cell.Cell, Nat) {
          if (phase == 0) {
            phase := 1;
            let live = h.nullLen - deadPop(st, s.deadOff, h.nullStart, h.nullLen);
            if (live > 0) return ?(null, live);
          };
          while (idx < h.distinct) {
            let (value, start, len) = HashSegment.keyDirEntry(st.region, h, e.keyType, idx);
            idx += 1;
            let live = len - deadPop(st, s.deadOff, start, len);
            if (live > 0) return ?(?value, live);
          };
          null;
        };
      };
    });

};
