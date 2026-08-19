/// A multi-column columnar store over a stable `Region`.
///
/// Rows are appended into a heap write-buffer, then flushed as immutable,
/// column-major segments into the Region: each segment lays out, per column, a
/// validity bitmap followed by either a word-aligned block of fixed-width cells
/// (`#nat/#int/#float/#bool`) or, for a variable-width `#text` column, an
/// offsets array plus a packed byte buffer. A
/// per-segment footer keeps each column's live count, null count, min, max, and
/// a maintained running sum; deletes are logical (the row is tombstoned and, once
/// flushed, the owning segment's sums adjusted), so segment bytes are never
/// rewritten and no compaction is needed. A deleted row's VALUES survive in the
/// segment either way — a buffered delete stashes its cells for the flush to
/// write — which is what lets an index committed later reconcile against them.
///
/// Row identity is a dense logical row-id assigned at append. Ids below the
/// flush watermark live in a segment; ids at or above it live in the buffer.
/// Reads and folds union both sides, so a query sees one consistent table.
///
/// `State` is pure data plus a `Region` handle, so a consuming actor persists it
/// directly under enhanced orthogonal persistence — no `stable` keyword, no
/// upgrade hooks. A secondary index is out of scope here; a query layer supplies
/// it. (a `Blob` at the OQL layer renders as `#text`, so `#text` covers it.)
///
/// HARD CONSTRAINT — the schema is fixed for the life of the store. The column
/// count and their types are chosen once, in `new`, and cannot change once any
/// data has been flushed. A flushed segment is a committed physical byte layout
/// in the Region; that layout is preserved verbatim across upgrades but is never
/// reshaped, because the Region holds untyped bytes that sit outside the
/// language's automatic state migration. There is therefore no adding, dropping,
/// or retyping a column in place — evolving the schema means creating a new store
/// with the new columns and re-writing the rows into it. Use this backend only
/// for tables whose shape is stable; a table whose schema changes belongs in a
/// heap-resident store, which the runtime can migrate.
import Region "mo:core/Region";
import Blob "mo:core/Blob";
import List "mo:core/List";
import Set "mo:core/Set";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import Cell "Cell";
import Image "Image";

module {

  let WORD : Nat64 = 8;
  let PAGE : Nat64 = 65536;

  /// Immutable per-column summary over the rows live at flush time.
  public type Footer = {
    count : Nat; // non-null cells
    nulls : Nat;
    min : ?Cell.Cell;
    max : ?Cell.Cell;
  };

  public type Segment = {
    start : Nat; // first row-id
    rows : Nat; // rows in this segment
    colBase : [Nat64]; // byte offset of each column's [bitmap | values] block
    footers : [Footer];
    liveSum : [var Cell.Sum]; // per column; adjusted on delete — mutated stable-side state
    liveCount : [var Nat]; // per column; live non-null cells, adjusted on delete (for avg)
  };

  public type State = {
    region : Region.Region;
    cols : [Cell.ColType];
    flushEvery : Nat; // append auto-flushes once the buffer holds this many rows (0 ⟺ manual flush only)
    flushBytes : Nat; // append auto-flushes once the buffer's approx byte size reaches this (0 ⟺ off)
    var end : Nat64; // next free byte in the region
    var watermark : Nat; // flushed row count
    // Positions that arrived as a SEGMENT IMAGE, as opposed to `append`. Equal to
    // `watermark + buffer.size()` for a table that has only ever been bulk-loaded; less
    // than it the moment an ordinary write lands. That difference is the drift between
    // the producer's FILE cursor and the table's POSITION cursor, and it is the only
    // way to detect it — once an appended row flushes, its segment is indistinguishable
    // from an image's.
    var imageRows : Nat;
    // The frontier just after the most recent ordinary `append` — 0 on a table that has
    // only ever been loaded. A region index whose coverage reaches this has every
    // appended position in its base, which is what makes a further load safe: the
    // producer's next index segment starts at or above it and cannot claim a position
    // holding a row that was never in the file.
    var lastAppendEnd : Nat;
    var bufferBytes : Nat; // running approximate byte size of the current buffer (reset on flush)
    buffer : List.List<?[?Cell.Cell]>; // row-major; outer null ⟺ deleted row, inner null ⟺ null cell
    // Cells of the rows deleted while buffered, by position, held until the flush
    // that materialises them. A flushed row's delete is logical — its bytes stay
    // in the segment, which is what lets an index committed later read the key its
    // posting sits under — so a buffered delete must not lose them either: `flush`
    // writes these into the segment exactly like a live row's and tombstones the
    // position. Cleared by every flush, so it never holds more than one buffer's
    // worth.
    bufferDead : List.List<(Nat, [?Cell.Cell])>;
    segments : List.List<Segment>;
    // Segments that arrived AHEAD of the frontier, waiting for the gap before them
    // to fill. A producer may have several images in flight, and messages from one
    // caller have no execution order, so an image can land before its predecessor.
    // These are deliberately NOT in `segments`: everything that reads the store —
    // every fold, the zone-map walk, position lookup — treats `segments` as the
    // contiguous rows below the watermark, and a staged segment must stay invisible
    // until it is promoted, or a query would see rows the table does not yet have.
    staged : List.List<Segment>;
    deleted : Set.Set<Nat>; // tombstoned flushed row-ids
  };

  // How many out-of-order segments may wait at once. Bounds the memory a producer
  // can pin by never sending the gap: each holds only its descriptor, since the
  // bytes are already in the Region.
  let MAX_STAGED = 16;

  /// Create an empty store over the given columns. `cols` fixes the schema for
  /// the life of the store — it cannot change once data is flushed (see the
  /// module header). Order matters: cells in `append` and reads by column index
  /// follow this order. `flushEvery` is the buffer high-water mark (in rows) at
  /// which `append` flushes on its own (0 disables the row trigger). `flushBytes`
  /// is a second, byte-based trigger: `append` also flushes once the buffer's
  /// approximate byte size reaches it (0 disables it), so segments stay uniform
  /// in bytes regardless of row width. With both set, whichever fires first wins;
  /// with both 0, flushing is entirely the caller's job.
  public func new(cols : [Cell.ColType], flushEvery : Nat, flushBytes : Nat) : State {
    // A zero-stride #bytes column would make every block and read degenerate
    // (0-byte cells, 0-length blocks); refuse at declaration, once, rather than
    // reason about it at every offset computation downstream.
    for (t in cols.values()) {
      switch (Cell.bytesWidth(t)) {
        case (?0) Runtime.trap("Columnar.new: a #bytes column needs a positive width");
        case _ {};
      };
    };
    {
    region = Region.new();
    cols;
    flushEvery;
    flushBytes;
    var end = 0;
    var watermark = 0;
    var imageRows = 0;
    var lastAppendEnd = 0;
    var bufferBytes = 0;
    buffer = List.empty<?[?Cell.Cell]>();
    bufferDead = List.empty<(Nat, [?Cell.Cell])>();
    segments = List.empty<Segment>();
    staged = List.empty<Segment>();
    deleted = Set.empty<Nat>();
    };
  };

  // Approximate on-disk byte size of a row: a fixed-width cell is one 8-byte
  // word; a text cell is its UTF-8 length (chars ≈ bytes for the common case);
  // a null cell contributes nothing but its validity bit. Used only to pace the
  // byte-budget flush, so an estimate is fine.
  func rowBytes(row : [?Cell.Cell]) : Nat {
    var b = 0;
    for (cell in row.values()) {
      switch cell {
        case (? #text t) b += t.size();
        case (? #bytes bl) b += bl.size();
        case (?_) b += 8;
        case null {};
      };
    };
    b;
  };

  public func columns(self : State) : Nat = self.cols.size();

  /// Append one row (one optional cell per column); returns its logical row-id.
  /// The row goes to the write buffer; once the buffer reaches `flushEvery` it
  /// is flushed into a segment (moving those rows off the heap). The returned id
  /// is stable across that flush.
  public func append(self : State, row : [?Cell.Cell]) : Nat {
    assert row.size() == self.cols.size();
    // A `#bytes` column's stride is fixed at declaration: every cell must be
    // exactly `w` bytes, or reads at stride `w` would slice the wrong rows.
    var bc = 0;
    while (bc < row.size()) {
      switch (self.cols[bc], row[bc]) {
        case (#bytes w, ?#bytes b) {
          if (b.size() != w) Runtime.trap("Columnar.append: column " # bc.toText() # " is #bytes(" # w.toText() # ") but the cell is " # b.size().toText() # " bytes");
        };
        case (#bytes w, ?_) Runtime.trap("Columnar.append: column " # bc.toText() # " is #bytes(" # w.toText() # ") but the cell is not #bytes");
        case _ {};
      };
      bc += 1;
    };
    let id = self.watermark + self.buffer.size();
    self.buffer.add(?row);
    self.lastAppendEnd := id + 1;
    self.bufferBytes += rowBytes(row);
    if (
      (self.flushEvery != 0 and self.buffer.size() >= self.flushEvery) or
      (self.flushBytes != 0 and self.bufferBytes >= self.flushBytes)
    ) flush(self);
    id;
  };

  func ensureBytes(region : Region.Region, bytes : Nat64) {
    let have = region.size() * PAGE;
    if (have < bytes) {
      // `grow` returns this sentinel (not a trap) when the request exceeds the
      // `--max-stable-pages` cap. Ignoring it lets the store below write past the
      // region and trap with a bare "out-of-bounds access" — so name the real
      // cause. The 4 GiB default (~106M rows here) is the one a consuming project
      // hits when it forgets to raise the flag; a dependency's own does not apply.
      if (region.grow((bytes - have + PAGE - 1) / PAGE) == 0xFFFF_FFFF_FFFF_FFFF) {
        Runtime.trap("Columnar: stable-memory Region is full — raise --max-stable-pages in the consuming project's [moc] args");
      };
    };
  };

  func bitmapWords(rows : Nat) : Nat = (rows + 63) / 64;

  // ── Flush ──────────────────────────────────────────────────────────────

  /// Transpose the whole buffer into one immutable column-major segment, build
  /// its footers and live-sums, advance the watermark, and clear the buffer.
  public func flush(self : State) {
    let n = self.buffer.size();
    if (n == 0) return;
    // A flush takes the rows at the frontier — exactly the range a staged segment is
    // waiting to occupy. Refuse rather than hand the same positions to both.
    if (self.staged.size() > 0)
      Runtime.trap("Columnar.flush: " # self.staged.size().toText() # " segment(s) are staged ahead of row " # self.watermark.toText() # " — finish the load before appending");
    let start = self.watermark;
    let C = self.cols.size();

    // materialize the buffer once for repeated per-column passes
    let rows = self.buffer.toArray();

    // Rows deleted while buffered, scattered back into their local slots. Their
    // cells are written into the segment like any other row's — a delete is
    // logical here as it is after a flush — but they are NOT live at flush time,
    // so they count toward `nulls` and stay out of the count/sum/min/max the
    // footer carries. The tombstone loop below keeps the position dead.
    let deadCells = VarArray.repeat<?[?Cell.Cell]>(null, n);
    for ((pos, cs) in self.bufferDead.values()) deadCells[pos - start] := ?cs;
    func cellsAt(idx : Nat) : (?[?Cell.Cell], Bool) = switch (rows[idx]) {
      case (?r) (?r, true);
      case null (deadCells[idx], false);
    };

    let colBase = VarArray.repeat<Nat64>(0, C);
    let footers = VarArray.repeat<Footer>({ count = 0; nulls = 0; min = null; max = null }, C);
    let liveSum = VarArray.repeat<Cell.Sum>(#int(0), C);
    let liveCount = VarArray.repeat<Nat>(0, C);

    let vWords = bitmapWords(n);
    let colBytes = Nat64.fromNat(vWords) * WORD + Nat64.fromNat(n) * WORD; // fixed-width block size
    let EMPTY = Text.encodeUtf8(""); // filler for the per-row byte array of a var-width column

    var c = 0;
    label cols while (c < C) {
      let base = self.end;
      colBase[c] := base;

      switch (Cell.bytesWidth(self.cols[c])) {
        case (?width) {
          // #bytes column: [ validity bitmap | n × width raw bytes, padded to 8 ].
          // Opaque to the query layer — no zone map, no sum — so the footer
          // carries counts only. Null cells and the padding tail are zeroed so a
          // flushed block and a segment-image block stay byte-comparable.
          let valuesBase = base + Nat64.fromNat(vWords) * WORD;
          let dataLen = Nat64.fromNat(n * width);
          let blockEnd = (valuesBase + dataLen + WORD - 1) / WORD * WORD;
          ensureBytes(self.region, blockEnd);
          let valid = VarArray.repeat<Nat64>(0, vWords);
          let zero = Blob.fromArray(Array.tabulate<Nat8>(width, func _ = 0));
          var live = 0;
          var nulls = 0;
          var idx = 0;
          while (idx < n) {
            let off = valuesBase + Nat64.fromNat(idx * width);
            let (cells, isLive) = cellsAt(idx);
            let cell : ?Cell.Cell = switch cells { case (?r) r[c]; case null null };
            switch cell {
              case (?#bytes b) {
                self.region.storeBlob(off, b);
                valid[idx / 64] := valid[idx / 64] | ((1 : Nat64) << Nat64.fromNat(idx % 64));
                // A row deleted while buffered (isLive false, cells from the
                // bufferDead stash) is written valid-but-tombstoned, exactly as
                // the fixed branch writes it: the bytes stay readable through
                // `rawRow`, the footer counts the row null, and the tombstone —
                // which `bytesRuns`' `live()` checks — is what keeps it dead.
                if (isLive) live += 1 else nulls += 1;
              };
              case _ { self.region.storeBlob(off, zero); nulls += 1 };
            };
            idx += 1;
          };
          var p = valuesBase + dataLen;
          while (p < blockEnd) { self.region.storeNat8(p, 0); p += 1 };
          var w = 0;
          while (w < vWords) { self.region.storeNat64(base + Nat64.fromNat(w) * WORD, valid[w]); w += 1 };
          footers[c] := { count = live; nulls; min = null; max = null };
          liveSum[c] := #int(0);
          liveCount[c] := live;
          self.end := blockEnd;
          c += 1;
          continue cols;
        };
        case null {};
      };

      if (Cell.isVar(self.cols[c])) {
        // Variable-width column: [ validity bitmap | (n+1) offsets | packed bytes ].
        let valid = VarArray.repeat<Nat64>(0, vWords);
        let offsets = VarArray.repeat<Nat64>(0, n + 1);
        let bytesOf = VarArray.repeat<Blob>(EMPTY, n);
        var running : Nat64 = 0;
        var live = 0;
        var nulls = 0;
        var idx = 0;
        while (idx < n) {
          offsets[idx] := running;
          let (cells, isLive) = cellsAt(idx);
          let cell : ?Cell.Cell = switch cells { case (?r) r[c]; case null null };
          switch cell {
            case (?#text t) {
              let b = t.encodeUtf8();
              bytesOf[idx] := b;
              running += Nat64.fromNat(b.size());
              valid[idx / 64] := valid[idx / 64] | ((1 : Nat64) << Nat64.fromNat(idx % 64));
              if (isLive) live += 1 else nulls += 1;
            };
            case _ { nulls += 1 };
          };
          idx += 1;
        };
        offsets[n] := running;
        let offsetsBase = base + Nat64.fromNat(vWords) * WORD;
        let dataBase = offsetsBase + Nat64.fromNat(n + 1) * WORD;
        ensureBytes(self.region, dataBase + running);
        var w = 0;
        while (w < vWords) { self.region.storeNat64(base + Nat64.fromNat(w) * WORD, valid[w]); w += 1 };
        var oi = 0;
        while (oi <= n) { self.region.storeNat64(offsetsBase + Nat64.fromNat(oi) * WORD, offsets[oi]); oi += 1 };
        idx := 0;
        while (idx < n) {
          if (offsets[idx + 1] > offsets[idx]) self.region.storeBlob(dataBase + offsets[idx], bytesOf[idx]);
          idx += 1;
        };
        footers[c] := { count = live; nulls; min = null; max = null }; // no zone map for text (v1)
        liveSum[c] := #int(0);
        liveCount[c] := live;
        // Pad the packed bytes out to a word so the NEXT column's block starts
        // 8-aligned. This is also what makes a flushed block and a segment image
        // block byte-comparable: an image pads every block, so without this the
        // two layouts would diverge on any text column whose bytes are not a
        // multiple of eight. Segment metadata records each column's base, so
        // earlier segments written without the padding still read correctly.
        self.end := (dataBase + running + WORD - 1) / WORD * WORD;
      } else {
        // Fixed-width column: [ validity bitmap | n words ].
        ensureBytes(self.region, base + colBytes);
        let valuesBase = base + Nat64.fromNat(vWords) * WORD;
        let valid = VarArray.repeat<Nat64>(0, vWords);
        var live = 0;
        var nulls = 0;
        var mn : ?Cell.Cell = null;
        var mx : ?Cell.Cell = null;
        var sum = Cell.zeroSum(self.cols[c]);
        var idx = 0;
        while (idx < n) {
          let off = valuesBase + Nat64.fromNat(idx) * WORD;
          let (cells, isLive) = cellsAt(idx);
          let cell : ?Cell.Cell = switch cells { case (?r) r[c]; case null null };
          switch cell {
            case (?v) {
              Cell.store(self.region, off, v);
              valid[idx / 64] := valid[idx / 64] | ((1 : Nat64) << Nat64.fromNat(idx % 64));
              if (isLive) {
                live += 1;
                sum := Cell.addSum(sum, v);
                mn := ?(switch mn { case (?m) if (Cell.lt(v, m)) v else m; case null v });
                mx := ?(switch mx { case (?m) if (Cell.lt(m, v)) v else m; case null v });
              } else nulls += 1;
            };
            case null { self.region.storeNat64(off, 0); nulls += 1 };
          };
          idx += 1;
        };
        var w = 0;
        while (w < vWords) { self.region.storeNat64(base + Nat64.fromNat(w) * WORD, valid[w]); w += 1 };
        footers[c] := { count = live; nulls; min = mn; max = mx };
        liveSum[c] := sum;
        liveCount[c] := live;
        self.end := valuesBase + Nat64.fromNat(n) * WORD;
      };
      c += 1;
    };

    // A row deleted while buffered stays a tombstone after the flush. Its cells
    // are in the segment (see `delete`); the tombstone is what makes it dead.
    var i = 0;
    while (i < n) {
      switch (rows[i]) { case null self.deleted.add(start + i); case (?_) {} };
      i += 1;
    };

    self.segments.add({
      start;
      rows = n;
      colBase = Array.tabulate<Nat64>(C, func c = colBase[c]);
      footers = Array.tabulate<Footer>(C, func c = footers[c]);
      liveSum;
      liveCount;
    });
    self.watermark += n;
    self.buffer.clear();
    self.bufferDead.clear();
    self.bufferBytes := 0;
  };

  // ── Segment images ───────────────────────────────────────────────────────

  /// Place a pre-built segment image (see `Image`) into the Region and register
  /// it as a segment, returning the first row-id it occupies.
  ///
  /// The image's column blocks are already in the layout `flush` produces and its
  /// trailer carries the footers, so this is one `storeBlob` plus O(columns) of
  /// bookkeeping — no per-row work at all. That is the whole reason the format
  /// exists. The footer values are the producer's word (see the trust note in
  /// `Image`); `validate` checks everything structural.
  ///
  /// The bytes are written BEFORE they are validated, which is safe and
  /// deliberate: a `Blob` has no cheap random access (`Blob.toArray` would
  /// allocate eight bytes of array slot per image byte, exactly the churn this
  /// path avoids), while a Region does. Nothing is committed until validation
  /// passes, and a trap discards every state change of the message, the written
  /// bytes included — so an invalid image cannot leave the store altered.
  ///
  /// Buffered rows are flushed first: an image occupies a contiguous run of
  /// row-ids, so it cannot be interleaved with a partially filled buffer.
  /// `appendSegmentImageAt` at the frontier — the sequential case. Buffered rows are
  /// flushed first, so the frontier is read after they have taken their positions.
  public func appendSegmentImage(self : State, image : Blob) : Nat {
    if (self.buffer.size() > 0) flush(self);
    let start = self.watermark;
    ignore appendSegmentImageAt(self, image, start);
    start;
  };

  /// Place an image whose rows begin at `firstRow`. `firstRow == watermark` lands it
  /// directly; a LATER `firstRow` stages it and it is promoted once the gap before it
  /// fills, which is what lets a producer keep several images in flight without the
  /// arrival order deciding where rows go. Returns the row the image starts at.
  ///
  /// The bytes go wherever the Region has room — a segment records its own `colBase`
  /// offsets, so byte order and row order are independent. Only the ROW space has to
  /// be contiguous, and `watermark` is what keeps it so.
  ///
  /// Returns THIS image's row count, not how far the frontier moved: landing a segment
  /// can promote several staged ones at once, so the frontier is not a per-call answer.
  /// Read it with `count`/`Table.appended` instead.
  public func appendSegmentImageAt(self : State, image : Blob, firstRow : Nat) : Nat {
    // Before any check: buffered rows own the positions at the frontier, so they must
    // take them before `firstRow` is compared against it.
    if (self.buffer.size() > 0) flush(self);
    if (firstRow < self.watermark)
      Runtime.trap("Columnar.appendSegmentImageAt: rows from " # firstRow.toText() # " are already loaded (watermark " # self.watermark.toText() # ")");

    if (firstRow > self.watermark and self.staged.size() >= MAX_STAGED)
      Runtime.trap("Columnar.appendSegmentImageAt: " # MAX_STAGED.toText() # " segments already staged — send the segment at row " # self.watermark.toText() # " to drain them");

    // A segment starts 8-aligned. `flush` leaves `end` wherever a text column's
    // packed bytes ended, so align up here; the skipped bytes are never read.
    let base = (self.end + WORD - 1) / WORD * WORD;
    let len = image.size().toNat64();
    ensureBytes(self.region, base + len);
    self.region.storeBlob(base, image);

    let desc = switch (Image.validate(self.region, base, len, self.cols)) {
      case (#ok d) d;
      case (#err e) Runtime.trap("Columnar.appendSegmentImage: " # e);
    };

    let n = desc.rows;
    let start = firstRow;
    if (n == 0) return 0;   // nothing to register; the bytes stay scratch

    // Overlap, not just an equal start — checked here because the row count comes from
    // the validated image. A producer resuming an interrupted load reads the CONTIGUOUS
    // frontier, which sits behind anything still staged, so its next segment can span a
    // staged one and with different batch boundaries need not share a start. Admitting it
    // would strand the staged segment below the frontier, where it can never be promoted
    // and its already-acknowledged rows are simply gone. Refuse, so the producer sees the
    // collision and can clear the staged set and resume from the row count.
    let endRow = start + n;
    for (s in self.staged.values()) {
      if (start < s.start + s.rows and s.start < endRow)
        Runtime.trap("Columnar.appendSegmentImageAt: rows [" # start.toText() # ", " # endRow.toText() # ") overlap a segment staged at [" # s.start.toText() # ", " # (s.start + s.rows).toText() # ") — drop the staged segments and resume from the row count");
    };

    let C = self.cols.size();
    let colBase = VarArray.repeat<Nat64>(0, C);
    let footers = VarArray.repeat<Footer>({ count = 0; nulls = 0; min = null; max = null }, C);
    let liveSum = VarArray.repeat<Cell.Sum>(#int(0), C);
    let liveCount = VarArray.repeat<Nat>(0, C);

    var c = 0;
    while (c < C) {
      colBase[c] := base + desc.cols[c].blockOff;
      let f = Image.footerOf(self.region, base, desc.cols[c], self.cols[c]);
      footers[c] := { count = f.count; nulls = f.nulls; min = f.min; max = f.max };
      liveSum[c] := f.sum;
      liveCount[c] := f.count;
      c += 1;
    };

    let seg : Segment = {
      start;
      rows = n;
      colBase = Array.tabulate<Nat64>(C, func c = colBase[c]);
      footers = Array.tabulate<Footer>(C, func c = footers[c]);
      liveSum;
      liveCount;
    };
    self.end := base + desc.bodyLen;
    if (start == self.watermark) {
      self.segments.add(seg);
      self.watermark += n;
      self.imageRows += n;
      drainStaged(self);
    } else {
      self.staged.add(seg);
    };
    n;
  };

  // Promote every staged segment that has become contiguous. Each pass rebuilds the
  // waiting set, so a promoted segment leaves it immediately rather than lingering until
  // a later filter; with at most MAX_STAGED waiting the whole drain is bounded work.
  func drainStaged(self : State) {
    var moved = true;
    while (moved) {
      moved := false;
      let keep = List.empty<Segment>();
      for (s in self.staged.values()) {
        if (s.start == self.watermark) {
          self.segments.add(s);
          self.watermark += s.rows;
          self.imageRows += s.rows;
          moved := true;
        } else {
          keep.add(s);
        };
      };
      self.staged.clear();
      for (s in keep.values()) self.staged.add(s);
    };
    // Nothing may be left behind the frontier: the overlap guard in
    // `appendSegmentImageAt` is what makes that impossible, so one here is a broken
    // invariant — and silently discarding its rows is the one outcome worse than failing.
    for (s in self.staged.values()) {
      if (s.start < self.watermark)
        Runtime.trap("Columnar.drainStaged: a segment staged at row " # s.start.toText() # " is behind the frontier " # self.watermark.toText() # " — its rows cannot be placed");
    };
  };

  /// Segments waiting on a gap — non-zero only mid-load with several images in
  /// flight. A load is complete when this is 0 and the row count is what was sent.
  public func stagedCount(self : State) : Nat = self.staged.size();

  /// Discard every staged segment, returning how many were dropped. An interrupted load
  /// leaves segments waiting on a gap that its producer may never send; without this the
  /// table keeps refusing to flush and the load can never be restarted. Their Region
  /// bytes are not reclaimed — the store never rewrites committed space — so the cost of
  /// an abandoned load is bytes, not correctness. Rows the dropped segments carried are
  /// NOT in the table: resume from the row count, which never counted them.
  public func dropStaged(self : State) : Nat {
    let n = self.staged.size();
    self.staged.clear();
    n;
  };

  // ── Reads ────────────────────────────────────────────────────────────────

  // Segments are appended in increasing `start` and partition [0, watermark)
  // contiguously, so a binary search locates the owner of `id` in O(log #segs)
  // rather than a linear scan (this is what bounds large point/materialize
  // queries at scale).
  func segmentOf(self : State, id : Nat) : ?Segment {
    var lo = 0;
    var hi = self.segments.size();
    while (lo < hi) {
      let mid = lo + (hi - lo) / 2;
      switch (self.segments.get(mid)) {
        case (?seg) {
          if (id < seg.start) hi := mid
          else if (id >= seg.start + seg.rows) lo := mid + 1
          else return ?seg;
        };
        case null return null;
      };
    };
    null;
  };

  func isValid(self : State, seg : Segment, col : Nat, idx : Nat) : Bool {
    let word = self.region.loadNat64(seg.colBase[col] + Nat64.fromNat(idx / 64) * WORD);
    (word >> Nat64.fromNat(idx % 64)) & 1 == 1;
  };

  func cellAt(self : State, seg : Segment, col : Nat, idx : Nat) : ?Cell.Cell {
    if (not isValid(self, seg, col, idx)) return null;
    let vw = Nat64.fromNat(bitmapWords(seg.rows));
    switch (Cell.bytesWidth(self.cols[col])) {
      case (?width) {
        let valuesBase = seg.colBase[col] + vw * WORD;
        return ?#bytes(self.region.loadBlob(valuesBase + Nat64.fromNat(idx * width), width));
      };
      case null {};
    };
    if (Cell.isVar(self.cols[col])) {
      // [ bitmap | (rows+1) offsets | data ]: slice the data buffer by offsets.
      let offsetsBase = seg.colBase[col] + vw * WORD;
      let dataBase = offsetsBase + Nat64.fromNat(seg.rows + 1) * WORD;
      let o0 = self.region.loadNat64(offsetsBase + Nat64.fromNat(idx) * WORD);
      let o1 = self.region.loadNat64(offsetsBase + Nat64.fromNat(idx + 1) * WORD);
      let bytes = self.region.loadBlob(dataBase + o0, Nat64.toNat(o1 - o0));
      return ?#text(bytes.decodeUtf8() ?? "");
    };
    let valuesBase = seg.colBase[col] + vw * WORD;
    ?Cell.load(self.region, valuesBase + Nat64.fromNat(idx) * WORD, self.cols[col]);
  };

  /// Read one column's cell for a row-id; null if the row is deleted or the cell is null.
  public func getCell(self : State, id : Nat, col : Nat) : ?Cell.Cell {
    if (id >= self.watermark) {
      switch (self.buffer.get(id - self.watermark)) {
        case (??row) row[col];
        case _ null;
      };
    } else {
      if (self.deleted.contains(id)) return null;
      switch (segmentOf(self, id)) {
        case (?seg) cellAt(self, seg, col, id - seg.start);
        case null null;
      };
    };
  };

  /// Read a whole row by id; null if the row is deleted.
  public func getRow(self : State, id : Nat) : ?[?Cell.Cell] {
    if (id >= self.watermark) {
      switch (self.buffer.get(id - self.watermark)) {
        case (??row) ?row;
        case _ null;
      };
    } else {
      if (self.deleted.contains(id)) return null;
      switch (segmentOf(self, id)) {
        case (?seg) {
          let idx = id - seg.start;
          ?Array.tabulate<?Cell.Cell>(self.cols.size(), func c = cellAt(self, seg, c, idx));
        };
        case null null;
      };
    };
  };

  /// Resolve a live row's location ONCE and return a per-column accessor, so a
  /// caller can read only the columns it needs (lazy projection) without
  /// re-locating the row per column. `null` if the row is deleted/absent.
  /// The stored cells at FLUSHED position `id`, ignoring its tombstone. A delete is
  /// logical — segment bytes are never rewritten — so a deleted row's values stay
  /// readable, which is what lets an index committed after the delete reconcile
  /// itself against it. Ordinary reads must use `getRow`/`reader`, which drop
  /// deleted rows. `null` for a buffer position: nothing above the watermark is in
  /// a segment yet.
  public func rawRow(self : State, id : Nat) : ?[?Cell.Cell] {
    if (id >= self.watermark) return null;
    switch (segmentOf(self, id)) {
      case (?seg) {
        let idx = id - seg.start;
        ?Array.tabulate<?Cell.Cell>(self.cols.size(), func c = cellAt(self, seg, c, idx));
      };
      case null null;
    };
  };

  /// The tombstoned flushed positions, in no particular order.
  public func deletedPositions(self : State) : Iter.Iter<Nat> = self.deleted.values();

  public func reader(self : State, id : Nat) : ?(Nat -> ?Cell.Cell) {
    if (id >= self.watermark) {
      switch (self.buffer.get(id - self.watermark)) {
        case (??row) ?(func (col : Nat) : ?Cell.Cell = row[col]);
        case _ null;
      };
    } else {
      if (self.deleted.contains(id)) return null;
      switch (segmentOf(self, id)) {
        case (?seg) { let idx = id - seg.start; ?(func (col : Nat) : ?Cell.Cell = cellAt(self, seg, col, idx)) };
        case null null;
      };
    };
  };

  /// Resolve the flushed segment owning `id` ONCE for a run read: the end
  /// (exclusive) of the segment's position range, plus a cell accessor for
  /// column `col` over it. The run-wise counterpart of `reader`, for a caller
  /// walking many consecutive positions (the index-build walk): the segment
  /// search and the column's base arithmetic are paid once per run instead of
  /// once per row, and the validity word is re-read only when the position
  /// crosses into the next 64-row block — an ascending walk loads it once per
  /// block. The accessor takes STORE positions within the run (as `getCell`)
  /// and does NOT check tombstones: a run caller filters `deleted` itself,
  /// where the check hoists out of the loop when the set is empty. `null`
  /// when no flushed segment owns `id` (at or above the watermark).
  public func colRun(self : State, col : Nat, id : Nat) : ?(Nat, Nat -> ?Cell.Cell) {
    switch (segmentOf(self, id)) {
      case null null;
      case (?seg) {
        let end = seg.start + seg.rows;
        let vw = Nat64.fromNat(bitmapWords(seg.rows));
        let base = seg.colBase[col];
        var vWordAt = bitmapWords(seg.rows);   // out of range, so the first read loads
        var vWord : Nat64 = 0;
        func validAt(idx : Nat) : Bool {
          let w = idx / 64;
          if (w != vWordAt) { vWordAt := w; vWord := self.region.loadNat64(base + Nat64.fromNat(w) * WORD) };
          (vWord >> Nat64.fromNat(idx % 64)) & 1 == 1;
        };
        switch (Cell.bytesWidth(self.cols[col])) {
          case (?width) {
            let valuesBase = base + vw * WORD;
            return ?(end, func (pos : Nat) : ?Cell.Cell {
              let idx = pos - seg.start;
              if (not validAt(idx)) return null;
              ?#bytes(self.region.loadBlob(valuesBase + Nat64.fromNat(idx * width), width));
            });
          };
          case null {};
        };
        if (Cell.isVar(self.cols[col])) {
          let offsetsBase = base + vw * WORD;
          let dataBase = offsetsBase + Nat64.fromNat(seg.rows + 1) * WORD;
          ?(end, func (pos : Nat) : ?Cell.Cell {
            let idx = pos - seg.start;
            if (not validAt(idx)) return null;
            let o0 = self.region.loadNat64(offsetsBase + Nat64.fromNat(idx) * WORD);
            let o1 = self.region.loadNat64(offsetsBase + Nat64.fromNat(idx + 1) * WORD);
            let bytes = self.region.loadBlob(dataBase + o0, Nat64.toNat(o1 - o0));
            ?#text(bytes.decodeUtf8() ?? "");
          });
        } else {
          let t = self.cols[col];
          let valuesBase = base + vw * WORD;
          ?(end, func (pos : Nat) : ?Cell.Cell {
            let idx = pos - seg.start;
            if (not validAt(idx)) return null;
            ?Cell.load(self.region, valuesBase + Nat64.fromNat(idx) * WORD, t);
          });
        };
      };
    };
  };

  /// Positions of candidate rows for a `[lo, hi]` range on column `col`, using
  /// the per-segment footer min/max as a zone map: a flushed segment is SKIPPED
  /// only when its non-null [min, max] provably excludes the range (all cells
  /// below `lo`, or all above `hi`). Segments with a null footer extreme
  /// (all-null column) and the whole buffer are kept (conservative). The result
  /// is a SUPERSET of matches — deleted rows and non-matching cells are left for
  /// the caller/executor to drop — and it yields POSITIONS, so the caller can
  /// read lazily via `reader`. `lo`/`hi` null mean unbounded on that side (so
  /// `positionsWhere(col, null, null)` is a full scan of live positions).
  public func positionsWhere(self : State, col : Nat, lo : ?Cell.Cell, hi : ?Cell.Cell) : Iter.Iter<Nat> {
    let ranges = List.empty<(Nat, Nat)>(); // [start, endExclusive)
    for (seg in self.segments.values()) {
      let f = seg.footers[col];
      let below = switch (lo, f.max) { case (?l, ?mx) Cell.lt(mx, l); case _ false }; // max < lo
      let above = switch (hi, f.min) { case (?h, ?mn) Cell.lt(h, mn); case _ false }; // hi < min
      if (not below and not above) ranges.add((seg.start, seg.start + seg.rows));
    };
    let bufEnd = self.watermark + self.buffer.size();
    if (bufEnd > self.watermark) ranges.add((self.watermark, bufEnd));
    let rs = ranges.toArray();
    var ri = 0;
    var pos = if (rs.size() > 0) rs[0].0 else 0;
    {
      next = func() : ?Nat {
        loop {
          if (ri >= rs.size()) return null;
          if (pos < rs[ri].1) { let p = pos; pos += 1; return ?p };
          ri += 1;
          if (ri < rs.size()) pos := rs[ri].0;
        };
      };
    };
  };

  /// One run of a `#bytes` column, for an app-level scan (e.g. vector search)
  /// that reads raw bytes without materialising cells. A `#stored` run points
  /// straight into the Region: row `startRow + i` occupies bytes
  /// `[base + i·width, base + (i+1)·width)`, and `live(i)` says whether that row
  /// is readable (validity bit set, not tombstoned). A `#buffered` run covers the
  /// write buffer, whose cells are still on the heap (null ⟺ deleted row or null
  /// cell). Together the runs cover every position, in ascending order.
  public type BytesRun = {
    #stored : { region : Region.Region; base : Nat64; width : Nat; startRow : Nat; rows : Nat; live : Nat -> Bool };
    #buffered : { startRow : Nat; cells : [?Blob] };
  };

  /// Iterate a `#bytes` column as runs — one per flushed segment plus one for a
  /// non-empty buffer. Traps if `col` is not a `#bytes` column. This is an
  /// APP-LEVEL read: it bypasses the query layer entirely (and with it any
  /// per-caller scoping), so it must never be wired to an exposed endpoint that
  /// serves untrusted callers.
  public func bytesRuns(self : State, col : Nat) : Iter.Iter<BytesRun> {
    let ?width = Cell.bytesWidth(self.cols[col]) else Runtime.trap("Columnar.bytesRuns: column " # col.toText() # " is not a #bytes column");
    let runs = List.empty<BytesRun>();
    for (seg in self.segments.values()) {
      let base = seg.colBase[col] + Nat64.fromNat(bitmapWords(seg.rows)) * WORD;
      let s = seg;
      runs.add(#stored {
        region = self.region;
        base;
        width;
        startRow = seg.start;
        rows = seg.rows;
        live = func (i : Nat) : Bool =
          isValid(self, s, col, i) and not self.deleted.contains(s.start + i);
      });
    };
    if (self.buffer.size() > 0) {
      runs.add(#buffered {
        startRow = self.watermark;
        cells = self.buffer.toArray().map(func (row : ?[?Cell.Cell]) : ?Blob =
          switch row { case (?r) switch (r[col]) { case (?#bytes b) ?b; case _ null }; case null null });
      });
    };
    runs.values();
  };

  /// Positions that arrived as a segment image. A caller comparing this against the
  /// total row count learns whether any position came from somewhere else.
  public func imageRows(self : State) : Nat = self.imageRows;

  /// The frontier just after the most recent ordinary `append`; 0 if there has never
  /// been one. An index covering up to here holds every appended position.
  public func lastAppendEnd(self : State) : Nat = self.lastAppendEnd;

  /// Iterate live rows as (row-id, row) pairs.
  public func scan(self : State) : Iter.Iter<(Nat, [?Cell.Cell])> {
    let total = self.watermark + self.buffer.size();
    var id = 0;
    {
      next = func() : ?(Nat, [?Cell.Cell]) {
        loop {
          if (id >= total) return null;
          let here = id;
          id += 1;
          switch (getRow(self, here)) { case (?row) return ?(here, row); case null {} };
        };
      };
    };
  };

  // ── Delete ─────────────────────────────────────────────────────────────

  /// Logical delete: clear a buffered row's slot, or tombstone a flushed row and
  /// subtract each of its cells from the owning segment's live-sums.
  ///
  /// A buffered row's cells are STASHED before the slot is cleared. `flush` writes
  /// them into the segment like a live row's and leaves the position a tombstone,
  /// so the row reads back through `rawRow` — which is how an index committed
  /// after the flush finds the key run its posting sits under and marks it DEAD.
  /// Without the stash the flush would materialise an all-null row, the fold would
  /// probe the null run, no DEAD bit would be set, and the base's run arithmetic
  /// would count the row live for the life of the index.
  public func delete(self : State, id : Nat) {
    if (id >= self.watermark) {
      let idx = id - self.watermark;
      if (idx < self.buffer.size()) {
        switch (self.buffer.get(idx)) {
          case (??row) { self.bufferDead.add((id, row)); self.buffer.put(idx, null) };
          case _ {};   // already deleted — the stash holds its cells
        };
      };
    } else {
      if (self.deleted.contains(id)) return;
      switch (segmentOf(self, id)) {
        case (?seg) {
          let localIdx = id - seg.start;
          var c = 0;
          while (c < self.cols.size()) {
            switch (cellAt(self, seg, c, localIdx)) {
              case (?v) { seg.liveSum[c] := Cell.subSum(seg.liveSum[c], v); seg.liveCount[c] -= 1 };
              case null {};
            };
            c += 1;
          };
        };
        case null {};
      };
      self.deleted.add(id);
    };
  };

  // ── Folds ────────────────────────────────────────────────────────────────

  /// Sum a column over all live rows = Σ(segment live-sums) + the live buffer term.
  public func sumOf(self : State, col : Nat) : Cell.Sum {
    var acc = Cell.zeroSum(self.cols[col]);
    for (seg in self.segments.values()) {
      acc := switch (acc, seg.liveSum[col]) {
        case (#int a, #int b) #int(a + b);
        case (#float a, #float b) #float(a + b);
        case (x, _) x;
      };
    };
    for (row in self.buffer.values()) {
      switch row {
        case (?r) switch (r[col]) { case (?v) acc := Cell.addSum(acc, v); case null {} };
        case null {};
      };
    };
    acc;
  };

  /// The smallest / largest live NON-NULL cell of `col`, or `null` when no live row
  /// holds one. EXACT, so `min(col)` / `max(col)` can be answered without a row
  /// scan.
  ///
  /// A flushed segment whose live non-null count still equals its footer count has
  /// had nothing deleted from that column, so the footer extreme IS that segment's
  /// extreme — O(1) per segment, and O(segments) for a whole bulk-loaded table. A
  /// segment with deletes must be scanned over its live cells instead: a delete can
  /// remove the row that held the extreme, and a footer cannot be narrowed without
  /// looking. `#text` carries no zone map (v1), so its segments are always scanned.
  /// The write buffer is always scanned — it has no footer yet.
  public func minOf(self : State, col : Nat) : ?Cell.Cell = extremeOf(self, col, true);
  public func maxOf(self : State, col : Nat) : ?Cell.Cell = extremeOf(self, col, false);

  func extremeOf(self : State, col : Nat, wantMin : Bool) : ?Cell.Cell {
    // A #bytes column is opaque — it carries no order, so it has no extremes.
    switch (Cell.bytesWidth(self.cols[col])) { case (?_) return null; case null {} };
    var best : ?Cell.Cell = null;
    func take(c : ?Cell.Cell) {
      switch c {
        case null {};
        case (?v) switch best {
          case null best := ?v;
          case (?b) if (if wantMin { Cell.lt(v, b) } else { Cell.lt(b, v) }) best := ?v;
        };
      };
    };
    let scanned = Cell.isVar(self.cols[col]);      // no zone map for #text
    for (seg in self.segments.values()) {
      let f = seg.footers[col];
      if (not scanned and seg.liveCount[col] == f.count) {
        take(if wantMin { f.min } else { f.max });
      } else {
        var i = 0;
        while (i < seg.rows) {
          if (not self.deleted.contains(seg.start + i)) take(cellAt(self, seg, col, i));
          i += 1;
        };
      };
    };
    for (row in self.buffer.values()) {
      switch row { case (?r) take(r[col]); case null {} };
    };
    best;
  };

  /// Count of live NON-NULL cells in a column = Σ(segment live-counts) + the
  /// live buffer term. Pairs with `sumOf` to serve `avg` (sum / non-null count).
  public func countOf(self : State, col : Nat) : Nat {
    var n = 0;
    for (seg in self.segments.values()) n += seg.liveCount[col];
    for (row in self.buffer.values()) {
      switch row {
        case (?r) switch (r[col]) { case (?_) n += 1; case null {} };
        case null {};
      };
    };
    n;
  };

  /// Count of live rows across segments (minus tombstones) and the buffer.
  public func count(self : State) : Nat {
    var live = self.watermark - self.deleted.size();
    for (row in self.buffer.values()) {
      switch row { case (?_) live += 1; case null {} };
    };
    live;
  };
};
