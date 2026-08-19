/// The `#hash` index segment: the byte format a producer builds off-chain and
/// uploads into a table's aux region, plus the reference `build`/`validate` and
/// the read primitives the `Served` merge probes.
///
/// One index segment covers a CONTIGUOUS run of store positions — its row range
/// `[firstRow, firstRow + rows)` — of one column's values. A column's index is a
/// LIST of such segments tiling `[0, appended)`: the producer builds and uploads
/// one segment at a time, so its peak memory is one segment's worth rather than
/// the whole column's. Postings hold ABSOLUTE store positions, so the reader
/// unions segments with no remapping and the DEAD bitmap addresses them directly.
///
/// It answers point / IN / count / groupCount over its slice of loaded rows,
/// addressed by their dense store position. It mirrors `Image` in spirit — LE,
/// 8-aligned, validate-then-trust — but where an image is a column of values, this
/// is an index over one column's values: an open-addressed bucket table for the
/// probe, a key directory for the group walk, and a postings array of positions.
/// Unlike an image, this format's off-chain producer IS pinned byte for byte:
/// `test/HashSegment.test.mo` diffs `build` against the JS-built fixture in
/// `test/fixtures/HashSegmentFixture.mo`.
///
/// ```
/// header 64 B
///   0  u32 magic 'OQIH'   4  u16 version   6  u16 bucketShift   8  u16 maxProbe
///   16 u64 rows           24 u64 distinct
///   32 u64 keyDirOff      40 u64 postingsOff   48 u64 keyBytesOff
///   56 u32 nullStart      60 u32 nullLen            (bucketsOff is implied: 64)
/// buckets   (1<<bucketShift) x 24 B, load factor <= 0.5
///   0 u64 key   8 u32 postingStart   12 u32 postingLen
///   16 u32 textOff   20 u16 textLen   22 u16 flags   (bit0 occupied)
/// key dir   distinct x u32 bucket slots, sorted by raw key (bits, or bytes for text)
/// postings  rows x u64 ABSOLUTE store positions — the null run first, then key
///           runs in key-dir order; ascending within each run
/// key bytes packed UTF-8, text keys only, in key-dir order
/// ```
///
/// The header carries `rows` (the segment's position count), not its `firstRow`:
/// the reader needs neither (postings are absolute), and `validate` — an off-line
/// audit, not the commit path — is told `firstRow` by its caller (the directory
/// holds it). So a segment starting at 0 is byte-identical to the pre-segmented
/// format over the same rows.
///
/// Lookup: `slot = hash & mask`, linear probe, stop on an empty bucket (miss) or
/// a key match; `maxProbe` bounds the loop. A fixed key compares the raw u64 in
/// the bucket; a text key stores its hash in the bucket and its exact bytes at
/// `textOff`, so a 64-bit collision costs one extra read, never a wrong answer.
///
/// The null run is header-addressed (`nullStart`/`nullLen`, as position INDICES
/// into the postings array — the run is placed first, so `nullStart` is 0) and
/// sits outside the buckets: it serves `eq(col, null)` and `in [null, x]`, and
/// never appears among the key runs. A segment's postings — the null run plus
/// every key run — tile `[firstRow, firstRow + rows)` exactly. Only `validate` checks
/// that tiling, and it runs at TEST time, not in the canister: commit runs
/// `checkHeader`, which bounds `nullLen` by `rows` and says nothing about the runs. So
/// a producer that dropped the nulls would commit and then under-fetch every loaded
/// null row — which is why `test/HashSegment.test.mo` diffs the one producer's bytes
/// against `build` and audits them there, before any of it reaches a canister.
///
/// TRUST — as with `Image`, `validate` checks STRUCTURE (every read the reader
/// will make lands in bounds; buckets are probe-reachable; runs tile the position
/// space) but not CONTENT: that a posting names the row that actually holds the
/// key is the producer's word. The same producer wrote the data, so an oracle
/// check catches both together; a background audit walk would be the deeper
/// backstop.
///
/// The key directory is sorted by RAW key (u64 bits for a fixed column, byte
/// order for text), NOT by value order, so `min`/`max` are never served from it.
/// They come from an `#ordered` heap index, or — for any fixed-width column — from
/// the store's own segment footers; only a text column with no `#ordered` index
/// falls back to a scan. `groupCount` needs no value order (it is a histogram), so
/// the raw-key order it walks is exact.
import Blob    "mo:core/Blob";
import Int64   "mo:core/Int64";
import List    "mo:core/List";
import Map     "mo:core/Map";
import Nat     "mo:core/Nat";
import Nat64   "mo:core/Nat64";
import Region  "mo:core/Region";
import Runtime "mo:core/Runtime";
import Text    "mo:core/Text";
import VarArray "mo:core/VarArray";
import Cell    "Cell";
import Hash    "Hash";

module {

  let MAGIC : Nat32 = 0x4F514948;   // "OQIH"
  let VERSION : Nat16 = 1;

  let WORD : Nat64 = 8;
  let HEADER : Nat64 = 64;
  let BUCKET : Nat64 = 24;
  let FLAG_OCCUPIED : Nat16 = 1;

  func pad8(n : Nat64) : Nat64 = (n + 7) / 8 * 8;

  /// A key as this format sees it: a fixed cell's raw 64-bit word, or a text
  /// cell's UTF-8 bytes. `null` (an absent/`#null_` cell) is NOT a key — it goes
  /// to the header-addressed null run.
  public type Key = { #bits : Nat64; #text : Blob };

  /// The raw key word a `Cell` contributes. Fixed cells only — a text cell is a
  /// `#text` key. Traps on `#float`: `#hash` over a float column is deferred
  /// (its bits need a scratch Region to derive, which the read path can't take).
  func cellBits(c : Cell.Cell) : Nat64 = switch c {
    case (#nat n)   n;
    case (#int i)   i.toNat64();         // two's-complement bits, as Cell.store writes
    case (#bool b)  (if b 1 else 0);
    case (#float _) Runtime.trap("HashSegment: #hash over a #float column is deferred");  // deferred
    case (#text _)  Runtime.trap("HashSegment.cellBits: #text is not a fixed key");
    case (#bytes _) Runtime.trap("HashSegment.cellBits: a #bytes column cannot be a key");
  };

  /// The key a cell contributes, or `null` for the null run.
  public func keyOf(c : ?Cell.Cell) : ?Key = switch c {
    case null null;
    case (?(#text t)) ?#text(t.encodeUtf8());
    case (?other) ?#bits(cellBits(other));
  };

  func homeHash(k : Key) : Nat64 = switch k {
    case (#bits b) Hash.fixed(b);
    case (#text t) Hash.text(t);
  };

  // The u64 stored in a bucket's `key` field: a fixed key's bits, or a text
  // key's hash (its bytes live in the key-bytes section, compared on match).
  func bucketKey(k : Key) : Nat64 = switch k {
    case (#bits b) b;
    case (#text t) Hash.text(t);
  };

  // Smallest bucket count that is a power of two and at least 2*distinct (load
  // factor <= 0.5); at least one bucket. Returns (shift, buckets).
  func shiftFor(distinct : Nat) : (Nat, Nat) {
    var buckets = 1;
    var shift = 0;
    let need = distinct * 2;
    while (buckets < need) { buckets *= 2; shift += 1 };
    (shift, buckets);
  };

  // ── build (reference producer) ─────────────────────────────────────────────

  /// Build a hash index segment over the row range `[firstRow, firstRow + rows)`
  /// of one column, reading each cell through `cell(local)` for `local` in
  /// `[0, rows)`, into `scratch` (overwritten; reuse one Region across calls — a
  /// Region is never reclaimed). Returns the segment bytes.
  ///
  /// `cell` is LOCAL-indexed (0-based within the segment); the postings it emits
  /// are ABSOLUTE (`firstRow + local`), so a reader unions segments without
  /// remapping. This is the reference the off-chain builder is diffed against,
  /// byte for byte, and the shape `validate` re-derives.
  public func build(
    scratch : Region.Region,
    keyType : Cell.ColType,
    firstRow : Nat,
    rows : Nat,
    cell : (Nat) -> ?Cell.Cell,
  ) : Blob {
    let isText = Cell.isVar(keyType);

    // Group positions by key, ascending local first so each run is ascending. A
    // sorted `Map` yields its entries in raw-key order — the key-dir order.
    let nulls = List.empty<Nat>();
    let byBits = Map.empty<Nat64, List.List<Nat>>();
    let byText = Map.empty<Blob, List.List<Nat>>();
    var r = 0;
    while (r < rows) {
      let pos = firstRow + r;                         // absolute store position
      switch (keyOf(cell(r))) {
        case null nulls.add(pos);
        case (?(#bits b)) {
          switch (byBits.get(Nat64.compare, b)) {
            case (?l) l.add(pos);
            case null { let l = List.empty<Nat>(); l.add(pos); byBits.add(Nat64.compare, b, l) };
          };
        };
        case (?(#text t)) {
          switch (byText.get(Blob.compare, t)) {
            case (?l) l.add(pos);
            case null { let l = List.empty<Nat>(); l.add(pos); byText.add(Blob.compare, t, l) };
          };
        };
      };
      r += 1;
    };

    let distinct = if (isText) byText.size() else byBits.size();

    // Materialise the key directory (sorted, from the Map iteration order).
    let keyBitsA = VarArray.repeat<Nat64>(0, distinct);
    let bytesA = VarArray.repeat<Blob>("", distinct);
    let runs = VarArray.repeat<[Nat]>([], distinct);
    var i = 0;
    if (isText) {
      for ((t, l) in byText.entries()) { keyBitsA[i] := Hash.text(t); bytesA[i] := t; runs[i] := l.toArray(); i += 1 };
    } else {
      for ((b, l) in byBits.entries()) { keyBitsA[i] := b; runs[i] := l.toArray(); i += 1 };
    };

    // Open-address the keys, in key-dir order, so placement is deterministic and
    // the producer reproduces it exactly.
    let (shift, nbuckets) = shiftFor(distinct);
    let slotOf = VarArray.repeat<Nat>(0, distinct);
    let occupant = VarArray.repeat<Int>(-1, nbuckets);
    var maxProbe = 0;
    i := 0;
    while (i < distinct) {
      // nbuckets is a power of two, so `% nbuckets` is the low-bit mask.
      let home = Nat64.toNat(if (isText) keyBitsA[i] else Hash.fixed(keyBitsA[i])) % nbuckets;
      var p = 0;
      var slot = home;
      while (occupant[slot] != -1) { p += 1; slot := (slot + 1) % nbuckets };
      occupant[slot] := i;
      slotOf[i] := slot;
      if (p + 1 > maxProbe) maxProbe := p + 1;
      i += 1;
    };

    // Layout.
    let bucketsOff = HEADER;
    let keyDirOff = bucketsOff + (nbuckets).toNat64() * BUCKET;
    let postingsOff = pad8(keyDirOff + (distinct).toNat64() * 4);
    let keyBytesOff = postingsOff + (rows).toNat64() * WORD;
    var textTotal : Nat64 = 0;
    if (isText) { i := 0; while (i < distinct) { textTotal += (bytesA[i].size()).toNat64(); i += 1 } };
    let bodyLen = pad8(keyBytesOff + textTotal);

    let have = scratch.size() * 65536;
    if (have < bodyLen and scratch.grow((bodyLen - have + 65535) / 65536) == 0xFFFF_FFFF_FFFF_FFFF) {
      Runtime.trap("HashSegment.build: scratch Region cannot grow to " # bodyLen.toText() # " bytes — raise --max-stable-pages");
    };
    // Zero the whole body: buckets are sparse and the tail is padded, and a
    // segment must be byte-reproducible with no uninitialised gaps.
    var z : Nat64 = 0;
    while (z < bodyLen) { scratch.storeNat64(z, 0); z += WORD };

    // Header.
    scratch.storeNat32(0, MAGIC);
    scratch.storeNat16(4, VERSION);
    scratch.storeNat16(6, (shift).toNat16());
    scratch.storeNat16(8, (maxProbe).toNat16());
    scratch.storeNat64(16, (rows).toNat64());
    scratch.storeNat64(24, (distinct).toNat64());
    scratch.storeNat64(32, keyDirOff);
    scratch.storeNat64(40, postingsOff);
    scratch.storeNat64(48, keyBytesOff);
    scratch.storeNat32(56, 0);                       // nullStart: the null run is first
    scratch.storeNat32(60, (nulls.size()).toNat32());

    // Postings: null run first, then key runs in key-dir order. Record each
    // key's (postingStart, postingLen), and its packed-bytes placement.
    var cursor : Nat64 = 0;                          // position index into the postings array
    for (pos in nulls.values()) { scratch.storeNat64(postingsOff + cursor * WORD, (pos).toNat64()); cursor += 1 };
    let postingStart = VarArray.repeat<Nat>(0, distinct);
    let postingLen = VarArray.repeat<Nat>(0, distinct);
    let textOff = VarArray.repeat<Nat>(0, distinct);
    var byteCursor : Nat64 = 0;
    i := 0;
    while (i < distinct) {
      postingStart[i] := cursor.toNat();
      for (pos in runs[i].values()) { scratch.storeNat64(postingsOff + cursor * WORD, (pos).toNat64()); cursor += 1 };
      postingLen[i] := runs[i].size();
      if (isText) {
        textOff[i] := byteCursor.toNat();
        if (bytesA[i].size() > 0) scratch.storeBlob(keyBytesOff + byteCursor, bytesA[i]);
        byteCursor += (bytesA[i].size()).toNat64();
      };
      i += 1;
    };

    // Buckets, in slot order.
    i := 0;
    while (i < distinct) {
      let b = bucketsOff + (slotOf[i]).toNat64() * BUCKET;
      scratch.storeNat64(b, keyBitsA[i]);
      scratch.storeNat32(b + 8, (postingStart[i]).toNat32());
      scratch.storeNat32(b + 12, (postingLen[i]).toNat32());
      scratch.storeNat32(b + 16, (textOff[i]).toNat32());
      scratch.storeNat16(b + 20, (bytesA[i].size()).toNat16());
      scratch.storeNat16(b + 22, FLAG_OCCUPIED);
      i += 1;
    };

    // Key directory: bucket slot of each key in key-dir order.
    i := 0;
    while (i < distinct) { scratch.storeNat32(keyDirOff + (i).toNat64() * 4, (slotOf[i]).toNat32()); i += 1 };

    scratch.loadBlob(0, (bodyLen).toNat());
  };

  // ── reader ───────────────────────────────────────────────────────────────

  public type Header = {
    bucketShift : Nat;
    maxProbe : Nat;
    rows : Nat;
    distinct : Nat;
    bucketsOff : Nat64;
    keyDirOff : Nat64;
    postingsOff : Nat64;
    keyBytesOff : Nat64;
    nullStart : Nat;
    nullLen : Nat;
  };

  /// Read the header of a segment at `base`. Trusts the bytes — call only after
  /// `validate` has accepted the segment (or on the reference `build`'s output).
  public func readHeader(region : Region.Region, base : Nat64) : Header {
    {
      bucketShift = (region.loadNat16(base + 6)).toNat();
      maxProbe    = (region.loadNat16(base + 8)).toNat();
      rows        = (region.loadNat64(base + 16)).toNat();
      distinct    = (region.loadNat64(base + 24)).toNat();
      bucketsOff  = base + HEADER;
      keyDirOff   = base + region.loadNat64(base + 32);
      postingsOff = base + region.loadNat64(base + 40);
      keyBytesOff = base + region.loadNat64(base + 48);
      nullStart   = (region.loadNat32(base + 56)).toNat();
      nullLen     = (region.loadNat32(base + 60)).toNat();
    };
  };

  /// The ABSOLUTE store position stored at postings slot `slot`.
  public func positionAt(region : Region.Region, h : Header, slot : Nat) : Nat =
    (region.loadNat64(h.postingsOff + (slot).toNat64() * WORD)).toNat();

  // A bucket's fields.
  func bucketOccupied(region : Region.Region, h : Header, slot : Nat) : Bool =
    region.loadNat16(h.bucketsOff + (slot).toNat64() * BUCKET + 22) & FLAG_OCCUPIED == FLAG_OCCUPIED;

  /// Probe for `key`; the run `(postingStart, postingLen)` if present, else null.
  public func probe(region : Region.Region, h : Header, key : Key) : ?(Nat, Nat) {
    let nbuckets = numBuckets(h);
    if (nbuckets == 0 or h.distinct == 0) return null;
    let want = bucketKey(key);
    let home = (homeHash(key)).toNat() % nbuckets;
    var p = 0;
    while (p < h.maxProbe) {
      let slot = (home + p) % nbuckets;
      let b = h.bucketsOff + (slot).toNat64() * BUCKET;
      if (region.loadNat16(b + 22) & FLAG_OCCUPIED != FLAG_OCCUPIED) return null;   // empty ⟹ miss
      if (region.loadNat64(b) == want) {
        // Fixed keys match on the word; text keys must also match bytes.
        let hit = switch key {
          case (#bits _) true;
          case (#text t) {
            let tlen = (region.loadNat16(b + 20)).toNat();
            if (tlen != t.size()) false
            else if (tlen == 0) true
            else region.loadBlob(h.keyBytesOff + (region.loadNat32(b + 16)).toNat64(), tlen) == t;
          };
        };
        if (hit) return ?((region.loadNat32(b + 8)).toNat(), (region.loadNat32(b + 12)).toNat());
      };
      p += 1;
    };
    null;
  };

  func numBuckets(h : Header) : Nat { var n = 1; var s = 0; while (s < h.bucketShift) { n *= 2; s += 1 }; n };

  /// Read the key VALUE and its live-relevant run for the `i`-th key-dir entry —
  /// for the group walk. Returns the cell value (reconstructed from the bucket)
  /// and the run `(postingStart, postingLen)`.
  public func keyDirEntry(region : Region.Region, h : Header, keyType : Cell.ColType, i : Nat)
    : (Cell.Cell, Nat, Nat) {
    let slot = (region.loadNat32(h.keyDirOff + (i).toNat64() * 4)).toNat();
    let b = h.bucketsOff + (slot).toNat64() * BUCKET;
    let word = region.loadNat64(b);
    let start = (region.loadNat32(b + 8)).toNat();
    let len = (region.loadNat32(b + 12)).toNat();
    let value : Cell.Cell = switch keyType {
      case (#nat)  #nat(word);
      case (#int)  #int(Int64.fromNat64(word));
      case (#bool) #bool(word == 1);
      case (#text) {
        let tlen = (region.loadNat16(b + 20)).toNat();
        let bytes = if (tlen == 0) ("" : Blob) else region.loadBlob(h.keyBytesOff + (region.loadNat32(b + 16)).toNat64(), tlen);
        #text(bytes.decodeUtf8() ?? "");
      };
      case (#float) Runtime.trap("HashSegment: #float key is deferred");   // deferred
      case (#bytes _) Runtime.trap("HashSegment: a #bytes column cannot be a key");
    };
    (value, start, len);
  };

  /// The O(1) half of `validate`: this is a hash segment of a version we read, and
  /// every section offset the reader will follow is 8-aligned, in ascending order,
  /// non-overlapping, and inside `len`. Bounded work regardless of `rows`, so
  /// commit runs it on every segment — a malformed header would otherwise send the
  /// reader at arbitrary region bytes. It does NOT check the postings or the runs;
  /// that is the O(rows) pass in `validate`.
  public func checkHeader(region : Region.Region, base : Nat64, len : Nat64) : { #ok : Header; #err : Text } {
    if (len < HEADER) return #err("segment shorter than its header");
    if (region.loadNat32(base) != MAGIC) return #err("bad magic");
    if (region.loadNat16(base + 4) != VERSION) return #err("unsupported hash-segment version");
    let h = readHeader(region, base);
    let nbuckets = numBuckets(h);
    let bucketsEnd = HEADER + (nbuckets).toNat64() * BUCKET;
    let keyDirRel = h.keyDirOff - base;
    let postingsRel = h.postingsOff - base;
    let keyBytesRel = h.keyBytesOff - base;
    if (keyDirRel != bucketsEnd) return #err("key dir does not follow the buckets");
    if (postingsRel != pad8(keyDirRel + (h.distinct).toNat64() * 4)) return #err("postings not 8-aligned after the key dir");
    if (keyBytesRel != postingsRel + (h.rows).toNat64() * WORD) return #err("key bytes do not follow the postings");
    if (keyBytesRel > len) return #err("key bytes run past the segment");
    if (h.nullStart != 0) return #err("null run is not first in the postings");
    if (h.nullLen > h.rows) return #err("null run longer than the row space");
    #ok h;
  };

  // ── validate ───────────────────────────────────────────────────────────────

  /// Validate the segment at `base` (length `len`, over `keyType`, covering the
  /// row range `[firstRow, firstRow + appended)`). Checks STRUCTURE only, in one
  /// O(rows) pass: offsets aligned / in bounds / non-overlapping; every bucket the
  /// key directory NAMES reachable from its home within `maxProbe` with no gap (an
  /// occupied bucket the directory does not name is never visited, so a stray one
  /// is not caught); the key directory sorted and pointing at occupied buckets —
  /// distinct ones, since equal keys fail the sort; postings ascending per run with
  /// positions in `[firstRow, firstRow + appended)`; and the null run plus the key
  /// runs tiling that range exactly. `rows` (the header) must equal `appended`.
  ///
  /// This is an OFF-LINE audit / conformance check, NOT the commit path: the
  /// O(rows) walk below never runs per message at scale. `checkHeader` carries the
  /// O(1) part and IS on the commit path.
  public func validate(
    region : Region.Region,
    base : Nat64,
    len : Nat64,
    keyType : Cell.ColType,
    firstRow : Nat,
    appended : Nat,
  ) : { #ok : Header; #err : Text } {
    let h = switch (checkHeader(region, base, len)) { case (#err e) return #err e; case (#ok h) h };
    if (h.rows != appended) return #err("segment covers " # h.rows.toText() # " rows, expected " # appended.toText());
    let nbuckets = numBuckets(h);

    // The key directory: sorted by raw key, each pointing at a distinct occupied
    // bucket, and the runs tiling the postings slot space after the null run.
    var expectStart = h.nullLen;                 // key runs begin right after the null run
    var prevKey : Nat64 = 0;
    var prevBytes : Blob = "";
    var i = 0;
    while (i < h.distinct) {
      let slot = (region.loadNat32(h.keyDirOff + (i).toNat64() * 4)).toNat();
      if (slot >= nbuckets) return #err("key-dir slot out of range");
      let b = h.bucketsOff + (slot).toNat64() * BUCKET;
      if (region.loadNat16(b + 22) & FLAG_OCCUPIED != FLAG_OCCUPIED) return #err("key dir points at an empty bucket");
      let word = region.loadNat64(b);
      // Sorted, strictly increasing (distinct keys). Fixed by bits; text by bytes.
      if (Cell.isVar(keyType)) {
        let tlen = (region.loadNat16(b + 20)).toNat();
        let toff = (region.loadNat32(b + 16)).toNat64();
        if (h.keyBytesOff + toff + (tlen).toNat64() > base + len) return #err("a text key runs past the key bytes");
        let bytes = if (tlen == 0) ("" : Blob) else region.loadBlob(h.keyBytesOff + toff, tlen);
        if (i > 0 and not (prevBytes < bytes)) return #err("key dir is not sorted (text)");
        prevBytes := bytes;
      } else {
        if (i > 0 and not (prevKey < word)) return #err("key dir is not sorted");
        prevKey := word;
      };
      // Probe reachability: walking from the key's home reaches this slot within
      // maxProbe, with no empty bucket in between (the linear-probing invariant
      // a reader relies on to stop at the first empty).
      let key : Key = if (Cell.isVar(keyType)) {
        let tlen = (region.loadNat16(b + 20)).toNat();
        let bytes = if (tlen == 0) ("" : Blob) else region.loadBlob(h.keyBytesOff + (region.loadNat32(b + 16)).toNat64(), tlen);
        #text(bytes);
      } else #bits(word);
      let home = (homeHash(key)).toNat() % nbuckets;
      let disp = (slot + nbuckets - home) % nbuckets;
      if (disp >= h.maxProbe) return #err("occupied bucket not reachable within maxProbe");
      var t = 0;
      while (t < disp) {
        if (not bucketOccupied(region, h, (home + t) % nbuckets)) return #err("gap in a probe chain — a reader would stop short");
        t += 1;
      };
      // Run placement contiguous after the null run, in key-dir order.
      let start = (region.loadNat32(b + 8)).toNat();
      let plen = (region.loadNat32(b + 12)).toNat();
      if (start != expectStart) return #err("key runs are not contiguous in key-dir order");
      expectStart += plen;
      i += 1;
    };
    if (expectStart != h.rows) return #err("key runs plus the null run do not fill the row space");

    // Postings: ascending within every run, positions in [firstRow, firstRow +
    // rows), and every position distinct — which, with the slot tiling above,
    // means the runs tile that range exactly. One O(rows) pass with a coverage
    // bitmap indexed by `pos - firstRow`.
    let seen = VarArray.repeat<Nat64>(0, (h.rows + 63) / 64);
    // The null run (one ascending run at slots [0, nullLen)).
    switch (checkRun(region, h, firstRow, 0, h.nullLen, seen)) { case (?e) return #err(e); case null {} };
    i := 0;
    while (i < h.distinct) {
      let slot = (region.loadNat32(h.keyDirOff + (i).toNat64() * 4)).toNat();
      let b = h.bucketsOff + (slot).toNat64() * BUCKET;
      let start = (region.loadNat32(b + 8)).toNat();
      let plen = (region.loadNat32(b + 12)).toNat();
      switch (checkRun(region, h, firstRow, start, plen, seen)) { case (?e) return #err(e); case null {} };
      i += 1;
    };
    #ok(h);
  };

  // One run [start, start+len): positions ascending, each in [firstRow, firstRow +
  // rows), none seen before (set its coverage bit at pos - firstRow). Returns an
  // error text, or null on success.
  func checkRun(region : Region.Region, h : Header, firstRow : Nat, start : Nat, len : Nat, seen : [var Nat64]) : ?Text {
    var prev : Int = -1;
    var s = start;
    let end = start + len;
    let lastExcl = firstRow + h.rows;
    while (s < end) {
      let pos = positionAt(region, h, s);
      if (pos < firstRow or pos >= lastExcl) return ?"a posting position is out of range";
      if (prev >= pos) return ?"postings are not strictly ascending within a run";
      let rel = pos - firstRow;
      let w = rel / 64;
      let bit : Nat64 = (1 : Nat64) << (rel % 64).toNat64();
      if (seen[w] & bit == bit) return ?"a position appears in more than one posting";
      seen[w] := seen[w] | bit;
      prev := pos;
      s += 1;
    };
    null;
  };

};
