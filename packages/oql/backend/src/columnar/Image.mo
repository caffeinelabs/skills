/// The segment image: the byte format a producer builds off-chain and
/// `Columnar.appendSegmentImage` copies into a Region unchanged.
///
/// An image's column blocks are laid out EXACTLY as a flushed segment lays them
/// out, so ingesting one is a validated `Region.storeBlob` — no per-row
/// allocation, no transpose, no write buffer. `test/SegmentImage.test.mo` pins that
/// equality between the two IN-CANISTER write paths: the same rows through
/// `append`+`flush` and through `build` must agree byte for byte on a fixed-width
/// column, cell for cell on a text column, and on every footer.
///
/// Everything that can be computed per row is computed by the PRODUCER. The
/// footers — live count, null count, min, max, running sum — arrive in the image's
/// trailer, so ingest is O(columns) and not O(rows): for a table of fixed-width
/// columns the canister does no per-row work at all. A secondary index is the one
/// exception; postings are a heap structure and are built on-chain, as their own
/// job, over whatever segments exist.
///
/// ```
/// header — 32 bytes
///   0   u32  magic 'OQLS'   4  u16 version   6  u16 flags
///   8   u32  rows          12  u16 ncols    14  u16 reserved
///   16  u32  reserved      20  u32 reserved
///   24  u64  bodyLen                        (whole image, multiple of 8)
///
/// directory — ncols x 16 bytes, in the table's declared column order
///   0   u8   kind (0 fixed, 1 text, 2 bytes)   1  u8  offsetWidth (8 for text, 0 otherwise)
///   2   u16  reserved                 4  u32 stride (for kind 2; reserved/0 otherwise)
///   8   u32  blockOff                 12 u32 blockLen
///
/// footer trailer — ncols x 48 bytes, in the same order
///   0   u64  liveCount     8   u64 nulls
///   16  u64  min           24  u64 max      (as the column's own 8-byte cell)
///   32  u64  sumLo         40  u64 sumHi    (128-bit two's complement)
///
/// body — column blocks in directory order, each starting 8-aligned:
///   fixed: [ validity bitmap | rows words ]
///   text:  [ validity bitmap | (rows+1) offsets | packed UTF-8, padded to 8 ]
///   bytes: [ validity bitmap | rows × stride raw bytes, padded to 8 ]
/// ```
///
/// A column's block ALWAYS begins with its validity bitmap, and the values follow
/// it immediately: `Columnar.cellAt` derives the values base from the column base
/// by skipping exactly `bitmapWords(rows)` words, so an image that placed the
/// bitmap anywhere else could not be stored verbatim. A column with no nulls
/// therefore carries an all-ones bitmap rather than omitting it — an eighth of a
/// byte per row, against giving up the copy.
///
/// `min`/`max` are present only for a fixed-width column with a non-zero live
/// count; a text column carries no zone map, matching what `flush` writes. `sum`
/// is 128-bit because a per-column total readily exceeds 64 bits at scale, and a
/// silently truncated sum would be served as an answer. For a `#float` column the
/// sum is that column's IEEE-754 bits in `sumLo`.
///
/// TRUST — the footers are ANSWERS, not metadata: `Columnar.sumOf` serves `sum`
/// straight out of them, `Columnar.minOf`/`maxOf` RETURN their min/max as the
/// answer to `min(col)`/`max(col)`, and `positionsWhere` prunes whole segments on
/// the same bounds. Taking them from the producer is deliberate (the load endpoint
/// is controller-gated, and a controller can already install arbitrary code), but
/// NOTHING in the canister checks a footer's VALUE. A wrong `sum` is returned as the
/// sum; a wrong `min`/`max` is wrong twice over, returned verbatim as the extreme and
/// — when the bounds are too NARROW — pruning segments that hold real matches. Only
/// the structure is verified. A producer that computes footers correctly is therefore
/// part of the trusted base, which is why the load endpoints are controller-only.
/// Verifying conservatism would mean scanning, which is the work this format exists to
/// avoid. The check that does exist is end to end rather than byte level: the scale
/// verifiers load through the shipping producer and compare its ANSWERS against a JS
/// oracle over the same rows — `bench/scale/verify-import.mjs` (sum, zone-map-pruned
/// counts), `verify-join.mjs` (footer min/max), `verify-csv.mjs` (the text, float, bool
/// and signed-int columns). Nothing diffs the producer's BYTES against this module; see
/// `build`.

import Array   "mo:core/Array";
import Blob    "mo:core/Blob";
import Int     "mo:core/Int";
import Nat16   "mo:core/Nat16";
import Nat32   "mo:core/Nat32";
import Nat64   "mo:core/Nat64";
import Region  "mo:core/Region";
import Runtime "mo:core/Runtime";
import Text    "mo:core/Text";
import VarArray "mo:core/VarArray";
import Cell    "Cell";

module {

  let MAGIC : Nat32 = 0x4F514C53;   // "OQLS"
  let VERSION : Nat16 = 1;

  let WORD : Nat64 = 8;
  public let HEADER : Nat64 = 32;
  public let DIRENT : Nat64 = 16;
  let TRAILER : Nat64 = 48;

  let KIND_FIXED : Nat8 = 0;
  let KIND_TEXT : Nat8 = 1;
  // A fixed-stride raw-byte column: [ validity bitmap | rows × width bytes,
  // padded to 8 ]. The stride is carried in the directory's u32 at offset 4
  // (reserved until now, so version 1 images stay valid). No zone map, no sum.
  let KIND_BYTES : Nat8 = 2;

  let TWO64 : Int = 18_446_744_073_709_551_616;
  let TWO64_N : Nat = 18_446_744_073_709_551_616;

  /// One column's placement within an image, plus where its footer sits.
  type ColDir = {
    kind : Nat8;
    offsetWidth : Nat8;
    blockOff : Nat64;
    blockLen : Nat64;
    trailerOff : Nat64;
  };

  /// A validated image: everything a caller needs to place it and read it back.
  type Descriptor = {
    rows : Nat;
    bodyLen : Nat64;
    cols : [ColDir];
  };

  func bitmapWords(rows : Nat) : Nat = (rows + 63) / 64;
  func pad8(n : Nat64) : Nat64 = (n + 7) / 8 * 8;

  /// Byte offset at which the column blocks start — after the header, the
  /// directory and the trailer. Always 8-aligned (32 + 64·ncols).
  func bodyStart(ncols : Nat) : Nat64 =
    HEADER + (DIRENT + TRAILER) * (ncols).toNat64();

  func kindOf(t : Cell.ColType) : Nat8 = switch t {
    case (#text) KIND_TEXT;
    case (#bytes _) KIND_BYTES;
    case _ KIND_FIXED;
  };

  // ── build ────────────────────────────────────────────────────────────────

  /// Build an image for `rows` rows over `cols`, reading cells through
  /// `cell(row, col)`, and compute its footers. `scratch` is used as the byte
  /// buffer and its contents are overwritten; pass the same region across calls
  /// rather than creating one per image, since a Region is never reclaimed.
  ///
  /// This is the reference encoder and the only definition of the format. There is no
  /// byte-diff test behind that: nothing compares `tools/oql-ingest/encode.mjs` against
  /// what this writes. The hash-segment producer HAS such a test —
  /// `test/HashSegment.test.mo` against the JS-built `test/fixtures/HashSegmentFixture.mo`
  /// — and the image producer is the gap. Divergence surfaces only as a wrong query
  /// answer in a scale verifier, so bytes no query reads (reserved fields, block
  /// padding) are pinned by nothing.
  public func build(
    scratch : Region.Region,
    cols : [Cell.ColType],
    rows : Nat,
    cell : (Nat, Nat) -> ?Cell.Cell,
  ) : Blob {
    let C = cols.size();
    let bw = bitmapWords(rows).toNat64();
    let n64 = rows.toNat64();
    let EMPTY = "".encodeUtf8();   // filler for a null text cell

    // Text columns are encoded once up front: their packed size decides the
    // block layout, and re-encoding per pass would double the work.
    let packed = VarArray.repeat<[Blob]>([], C);
    var c = 0;
    while (c < C) {
      if (Cell.isVar(cols[c])) {
        let col = c;
        packed[c] := Array.tabulate<Blob>(rows, func (r : Nat) : Blob =
          switch (cell(r, col)) { case (?#text t) t.encodeUtf8(); case _ EMPTY });
      };
      c += 1;
    };

    // Lay the blocks out, then size the image.
    let offs = VarArray.repeat<Nat64>(0, C);
    let lens = VarArray.repeat<Nat64>(0, C);
    var cursor = bodyStart(C);
    c := 0;
    while (c < C) {
      offs[c] := cursor;
      lens[c] := switch (Cell.bytesWidth(cols[c])) {
        case (?w) bw * WORD + pad8(n64 * (w).toNat64());
        case null {
          if (Cell.isVar(cols[c])) {
            var total : Nat64 = 0;
            for (b in packed[c].values()) total += (b.size()).toNat64();
            bw * WORD + (n64 + 1) * WORD + pad8(total);
          } else {
            bw * WORD + n64 * WORD;
          };
        };
      };
      cursor += lens[c];
      c += 1;
    };
    let bodyLen = cursor;

    let have = scratch.size() * 65536;
    if (have < bodyLen and scratch.grow((bodyLen - have + 65535) / 65536) == 0xFFFF_FFFF_FFFF_FFFF) {
      Runtime.trap("Image.build: scratch Region cannot grow to " # bodyLen.toText() # " bytes — raise --max-stable-pages");
    };

    scratch.storeNat32(0, MAGIC);
    scratch.storeNat16(4, VERSION);
    scratch.storeNat16(6, 0);            // flags
    scratch.storeNat32(8, (rows).toNat32());
    scratch.storeNat16(12, (C).toNat16());
    scratch.storeNat16(14, 0);
    scratch.storeNat32(16, 0);           // reserved
    scratch.storeNat32(20, 0);          // reserved
    scratch.storeNat64(24, bodyLen);

    let trailerBase = HEADER + DIRENT * (C).toNat64();
    c := 0;
    while (c < C) {
      let d = HEADER + DIRENT * (c).toNat64();
      scratch.storeNat8(d, kindOf(cols[c]));
      scratch.storeNat8(d + 1, if (Cell.isVar(cols[c])) 8 else 0);
      scratch.storeNat16(d + 2, 0);
      // A #bytes column carries its stride here; 0 (reserved) for every other kind.
      scratch.storeNat32(d + 4, switch (Cell.bytesWidth(cols[c])) { case (?w) (w).toNat32(); case null 0 });
      scratch.storeNat32(d + 8, ((offs[c]).toNat()).toNat32());
      scratch.storeNat32(d + 12, ((lens[c]).toNat()).toNat32());
      c += 1;
    };

    // Blocks, and the footers over them in the same pass.
    c := 0;
    while (c < C) {
      let base = offs[c];
      let valuesBase = base + bw * WORD;
      let valid = VarArray.repeat<Nat64>(0, bitmapWords(rows));
      var live = 0;
      var nulls = 0;
      var mn : ?Cell.Cell = null;
      var mx : ?Cell.Cell = null;
      var sum = Cell.zeroSum(cols[c]);

      switch (Cell.bytesWidth(cols[c])) {
        case (?width) {
          // [ bitmap | rows × width raw bytes ]: null cells and the padding tail
          // are zeroed, matching what `flush` writes. Counts only — no zone map,
          // no sum (mn/mx/sum stay at their zero seeds for the trailer below).
          var i = 0;
          while (i < rows) {
            let off = valuesBase + (i * width).toNat64();
            switch (cell(i, c)) {
              case (?#bytes b) {
                if (b.size() != width) Runtime.trap("Image.build: column " # c.toText() # " is #bytes(" # width.toText() # ") but a cell is " # b.size().toText() # " bytes");
                scratch.storeBlob(off, b);
                valid[i / 64] := valid[i / 64] | ((1 : Nat64) << (i % 64).toNat64());
                live += 1;
              };
              case _ {
                var z = off;
                let zEnd = off + (width).toNat64();
                while (z < zEnd) { scratch.storeNat8(z, 0); z += 1 };
                nulls += 1;
              };
            };
            i += 1;
          };
          var p = valuesBase + (rows * width).toNat64();
          let blockEnd = base + lens[c];
          while (p < blockEnd) { scratch.storeNat8(p, 0); p += 1 };
        };
        case null {

      if (Cell.isVar(cols[c])) {
        let bytes = packed[c];
        let offsetsBase = valuesBase;
        let dataBase = offsetsBase + (n64 + 1) * WORD;
        var running : Nat64 = 0;
        var i = 0;
        while (i < rows) {
          scratch.storeNat64(offsetsBase + (i).toNat64() * WORD, running);
          // A null text cell keeps its offset slot (zero length), exactly as a
          // flushed segment does, so the two layouts stay byte-comparable.
          switch (cell(i, c)) {
            case (?#text _) {
              let b = bytes[i];
              if (b.size() > 0) scratch.storeBlob(dataBase + running, b);
              running += (b.size()).toNat64();
              valid[i / 64] := valid[i / 64] | ((1 : Nat64) << (i % 64).toNat64());
              live += 1;
            };
            case _ nulls += 1;
          };
          i += 1;
        };
        scratch.storeNat64(offsetsBase + n64 * WORD, running);
        // Pad the packed bytes out to the block length: an image must be
        // byte-reproducible, so it can carry no uninitialised gaps.
        var p = dataBase + running;
        let blockEnd = base + lens[c];
        while (p < blockEnd) { scratch.storeNat8(p, 0); p += 1 };
        // A text column carries no zone map, matching `flush`.
      } else {
        var i = 0;
        while (i < rows) {
          let off = valuesBase + (i).toNat64() * WORD;
          switch (cell(i, c)) {
            case (?v) {
              Cell.store(scratch, off, v);
              valid[i / 64] := valid[i / 64] | ((1 : Nat64) << (i % 64).toNat64());
              live += 1;
              sum := Cell.addSum(sum, v);
              mn := ?(switch mn { case (?m) if (Cell.lt(v, m)) v else m; case null v });
              mx := ?(switch mx { case (?m) if (Cell.lt(m, v)) v else m; case null v });
            };
            case null { scratch.storeNat64(off, 0); nulls += 1 };
          };
          i += 1;
        };
      };

        };
      };

      var w = 0;
      while (w < bitmapWords(rows)) { scratch.storeNat64(base + (w).toNat64() * WORD, valid[w]); w += 1 };

      // Trailer: the footers, in the column's own cell encoding so the canister
      // reads them back with the same `Cell.load` it uses for stored values.
      let t = trailerBase + TRAILER * (c).toNat64();
      scratch.storeNat64(t, (live).toNat64());
      scratch.storeNat64(t + 8, (nulls).toNat64());
      switch mn { case (?v) Cell.store(scratch, t + 16, v); case null scratch.storeNat64(t + 16, 0) };
      switch mx { case (?v) Cell.store(scratch, t + 24, v); case null scratch.storeNat64(t + 24, 0) };
      switch sum {
        case (#int s) {
          // 128-bit two's complement, low word first.
          let m : Int = if (s < 0) TWO64 * TWO64 + s else s;
          let n : Nat = Int.abs(m);
          scratch.storeNat64(t + 32, (n % TWO64_N).toNat64());
          scratch.storeNat64(t + 40, (n / TWO64_N).toNat64());
        };
        case (#float f) { scratch.storeFloat(t + 32, f); scratch.storeNat64(t + 40, 0) };
      };
      c += 1;
    };

    scratch.loadBlob(0, (bodyLen).toNat());
  };

  // ── validate ─────────────────────────────────────────────────────────────

  /// Validate an image already written to `region` at `base` against the declared
  /// columns. Returns the descriptor, or an error naming what failed.
  ///
  /// Reading from the Region rather than from the `Blob` is deliberate: a Blob has
  /// no cheap random access, and `Blob.toArray` would allocate eight bytes of
  /// array slot per image byte — the very churn this path exists to avoid. Writing
  /// before validating is safe because a trapped message discards every state
  /// change, Region writes included, and the caller commits nothing until this
  /// returns.
  ///
  /// What is checked is STRUCTURE: that every read the store will later perform
  /// lands inside the image. The footer VALUES are not checked — that would mean
  /// scanning (see the trust note in the module header).
  public func validate(
    region : Region.Region,
    base : Nat64,
    imageLen : Nat64,
    cols : [Cell.ColType],
  ) : { #ok : Descriptor; #err : Text } {
    let C = cols.size();
    if (imageLen < bodyStart(C)) return #err("image shorter than its own header");
    if (region.loadNat32(base) != MAGIC) return #err("bad magic");
    let ver = region.loadNat16(base + 4);
    if (ver != VERSION) return #err("unsupported version " # ver.toText());
    let ncols = (region.loadNat16(base + 12)).toNat();
    if (ncols != C) return #err("image has " # ncols.toText() # " columns, the table has " # C.toText());
    let bodyLen = region.loadNat64(base + 24);
    if (bodyLen != imageLen) return #err("bodyLen disagrees with the image size");
    if (bodyLen % 8 != 0) return #err("bodyLen is not a multiple of 8");

    let rows = (region.loadNat32(base + 8)).toNat();
    let bw = bitmapWords(rows).toNat64();
    let n64 = rows.toNat64();
    let bs = bodyStart(C);
    let trailerBase = HEADER + DIRENT * (C).toNat64();

    let dirs = VarArray.repeat<ColDir>(
      { kind = 0; offsetWidth = 0; blockOff = 0; blockLen = 0; trailerOff = 0 }, C);
    var prevEnd = bs;
    var c = 0;
    while (c < C) {
      let d = base + HEADER + DIRENT * (c).toNat64();
      let kind = region.loadNat8(d);
      let ow = region.loadNat8(d + 1);
      let off = ((region.loadNat32(d + 8)).toNat()).toNat64();
      let len = ((region.loadNat32(d + 12)).toNat()).toNat64();

      if (kind != kindOf(cols[c])) return #err("column " # c.toText() # ": kind does not match the declared column type");
      if (ow != (if (Cell.isVar(cols[c])) 8 else 0)) return #err("column " # c.toText() # ": offsetWidth must be 8 for text, 0 for fixed");
      switch (Cell.bytesWidth(cols[c])) {
        case (?w) {
          let dw = (region.loadNat32(d + 4)).toNat();
          if (dw != w) return #err("column " # c.toText() # ": image stride is " # dw.toText() # ", the table declares #bytes(" # w.toText() # ")");
        };
        case null {};
      };
      if (off % 8 != 0) return #err("column " # c.toText() # ": block is not 8-aligned");
      if (len % 8 != 0) return #err("column " # c.toText() # ": block length is not a multiple of 8");
      // Blocks partition the body in directory order: contiguous, ascending, no
      // overlap and no gaps. That is what makes every later read in-bounds by
      // construction rather than by a per-read check.
      if (off != prevEnd) return #err("column " # c.toText() # ": block does not follow the previous one");
      if (off + len > bodyLen) return #err("column " # c.toText() # ": block runs past the end of the image");

      let want = switch (Cell.bytesWidth(cols[c])) {
        case (?w) bw * WORD + pad8(n64 * (w).toNat64());
        case null if (Cell.isVar(cols[c])) bw * WORD + (n64 + 1) * WORD else bw * WORD + n64 * WORD;
      };
      if (len < want) return #err("column " # c.toText() # ": block too small for " # rows.toText() # " rows");
      if (not Cell.isVar(cols[c]) and len != want) return #err("column " # c.toText() # ": fixed-width block must be exactly bitmap + rows values");

      if (Cell.isVar(cols[c])) {
        // Offsets must be monotone, start at zero, and end within the packed
        // bytes — otherwise a text read slices outside the block. This is the one
        // remaining per-row check, and it is what keeps `loadBlob` in bounds.
        let offsetsBase = base + off + bw * WORD;
        let dataLen = len - bw * WORD - (n64 + 1) * WORD;
        if (region.loadNat64(offsetsBase) != 0) return #err("column " # c.toText() # ": first offset is not zero");
        var prev : Nat64 = 0;
        var i : Nat64 = 1;
        while (i <= n64) {
          let o = region.loadNat64(offsetsBase + i * WORD);
          if (o < prev) return #err("column " # c.toText() # ": offsets are not monotone");
          if (o > dataLen) return #err("column " # c.toText() # ": offset runs past the packed bytes");
          prev := o;
          i += 1;
        };
      };

      // The footer's live count cannot exceed the rows it describes; a live count
      // above `rows` would make `avg` divide by a denominator no scan could
      // produce, and `count` disagree with the row space.
      let tOff = trailerBase + TRAILER * (c).toNat64();
      let live = (region.loadNat64(base + tOff)).toNat();
      let nulls = (region.loadNat64(base + tOff + 8)).toNat();
      if (live + nulls != rows) return #err("column " # c.toText() # ": footer live+null count is " # (live + nulls).toText() # ", not " # rows.toText());

      dirs[c] := { kind; offsetWidth = ow; blockOff = off; blockLen = len; trailerOff = tOff };
      prevEnd := off + len;
      c += 1;
    };
    if (prevEnd != bodyLen) return #err("the column blocks do not fill the image");

    #ok({ rows; bodyLen; cols = Array.tabulate<ColDir>(C, func (i : Nat) : ColDir = dirs[i]) });
  };

  /// Read one column's footer out of a validated image in `region`.
  ///
  /// `min`/`max` decode with the same `Cell.load` the store uses for stored
  /// values, so their byte encoding is the column's own and needs no separate
  /// interpretation. They are reported only for a fixed-width column with a live
  /// cell — a text column carries no zone map, and an all-null column has no
  /// extremes, both matching what `flush` produces.
  public func footerOf(
    region : Region.Region,
    base : Nat64,
    dir : ColDir,
    colType : Cell.ColType,
  ) : { count : Nat; nulls : Nat; min : ?Cell.Cell; max : ?Cell.Cell; sum : Cell.Sum } {
    let t = base + dir.trailerOff;
    let count = (region.loadNat64(t)).toNat();
    let nulls = (region.loadNat64(t + 8)).toNat();
    let hasZone = not Cell.isVar(colType) and Cell.bytesWidth(colType) == null and count > 0;
    let sum : Cell.Sum = switch colType {
      case (#float) #float(region.loadFloat(t + 32));
      case (#text)  #int(0);
      case (#bytes _) #int(0);
      case _ {
        let lo = (region.loadNat64(t + 32)).toNat();
        let hi = region.loadNat64(t + 40);
        let n : Nat = (hi).toNat() * TWO64_N + lo;
        // Top bit of the high word ⟹ a negative total, stored two's complement.
        #int(if (hi >= 0x8000_0000_0000_0000) n - TWO64 * TWO64 else n);
      };
    };
    {
      count;
      nulls;
      min = if (hasZone) ?Cell.load(region, t + 16, colType) else null;
      max = if (hasZone) ?Cell.load(region, t + 24, colType) else null;
      sum;
    };
  };

};
