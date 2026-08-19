/// A columnar, Region-backed OQL table — an append log of typed rows with
/// on-heap secondary indexes, queried through OQL. It is deliberately NOT a
/// key-value map: rows are addressed by their dense store position (the primary
/// key), you `append` rows and query them, and there is no `get(k)`/`put(k,v)`.
/// That honest shape is why it is its own type rather than an `IndexedMap`
/// backend.
///
/// MEMORY: the flushed row data lives in a `Region` (off the GC heap, preserved
/// across upgrades under enhanced orthogonal persistence). The write buffer, the
/// secondary indexes, and the segment metadata stay on the heap. `Table` is pure
/// data — no stored functions — so a persistent `var` of this type survives an
/// upgrade directly.
///
/// Columns are the four numeric kinds (`#nat/#int/#float/#bool`, fixed-width)
/// plus variable-width `#text`; the `Value ⇄ Cell` mapping below is the one
/// place to widen further. Reuses `SecondaryIndex` and `Entity`
/// unchanged; the OQL executor/planner are untouched (a `Table` builds an
/// ordinary `Entity`, so it composes into a `Registry` alongside heap entities).

import Array   "mo:core/Array";
import Float   "mo:core/Float";
import Int     "mo:core/Int";
import Int64   "mo:core/Int64";
import Iter    "mo:core/Iter";
import List    "mo:core/List";
import Map     "mo:core/Map";
import Nat     "mo:core/Nat";
import Nat64   "mo:core/Nat64";
import Option  "mo:core/Option";
import Region  "mo:core/Region";
import Runtime "mo:core/Runtime";
import Set     "mo:core/Set";
import Text    "mo:core/Text";
import Cell    "columnar/Cell";
import Columnar "columnar/Columnar";
import HashSegment "columnar/HashSegment";
import Entity  "Entity";
import Predicate "Predicate";
import RegionIndex "RegionIndex";
import SecondaryIndex "SecondaryIndex";
import Types   "Types";

module {

  type Value = Types.Value;
  type Row   = [(Text, Value)];   // Entity.Row

  public type Kind = SecondaryIndex.Kind;

  /// A column declaration: a name paired with its cell type. Order is the
  /// storage order; reads by column index follow it.
  public type Column = (Text, Cell.ColType);

  /// A columnar table: the Region store, its column names (the store keeps only
  /// the cell types), the heap secondary indexes over row positions (the DELTA
  /// for a region-backed index), and `rix`, the per-table aux Region holding any
  /// region-resident index BASE segments. Pure data — `rix` adds a second Region
  /// and a small heap directory, both persisted directly under enhanced
  /// orthogonal persistence.
  public type Table = {
    store : Columnar.State;
    names : [Text];
    ix    : SecondaryIndex.Index<Nat>;
    rix   : RegionIndex.State;
  };

  // Default auto-flush high-water mark, in buffered rows (~a few MiB for typical
  // rows). Appends move to a segment automatically at this point.
  let DEFAULT_FLUSH_ROWS = 50_000;

  // Default byte-based auto-flush ceiling (~4 MiB). Guards against wide/text rows
  // building a huge buffer well before the row count trigger fires, keeping
  // segments uniform in bytes; whichever trigger fires first wins.
  let DEFAULT_FLUSH_BYTES = 4_000_000;

  // Rows per segment when the canister indexes its own appended rows (see
  // `absorbAppended`). Caps the builder's heap per segment, the way `--index-seg` caps the
  // producer's; the cost of a smaller value is more segments to merge at query time.
  let ABSORB_SEG = 100_000;

  // The table's own flush threshold is the better bound where it is set: it is already the
  // batch size this table was tuned for, and it makes the multi-chunk path reachable in a
  // test without a hundred thousand appends — which is how a wedge in that path went
  // unnoticed once already. 0 means manual flush only, so fall back to the constant.
  func absorbSeg(self : Table) : Nat =
    if (self.store.flushEvery > 0) Nat.min(self.store.flushEvery, ABSORB_SEG) else ABSORB_SEG;

  /// A fresh table over `columns`, with the given single-column `indexes`.
  public func new(columns : [Column], indexes : [(Text, Kind)]) : Table =
    newWith(columns, indexes, [], DEFAULT_FLUSH_ROWS);

  /// `new` with composite (multi-column, key-order) indexes and an explicit
  /// auto-flush threshold (buffered rows; 0 disables auto-flush). Traps if the
  /// column list is empty or if any indexed/composite column is not one of the
  /// declared columns — an index on an unstored column can't be materialised, so
  /// this turns a silent wrong-answer into a loud construction-time error.
  public func newWith(columns : [Column], indexes : [(Text, Kind)], composites : [([Text], Kind)], flushEvery : Nat) : Table {
    let names = columns.map<Column, Text>(func ((n, _t) : Column) : Text = n);
    let colTypes = columns.map<Column, Cell.ColType>(func ((_n, t) : Column) : Cell.ColType = t);
    if (names.size() == 0) Runtime.trap("Table.new: a table needs at least one column");
    for ((col, _kind) in indexes.values()) requireIndexable(names, colTypes, col);
    for ((cols, _kind) in composites.values()) { for (col in cols.values()) requireIndexable(names, colTypes, col) };
    {
      store = Columnar.new(colTypes, flushEvery, DEFAULT_FLUSH_BYTES);
      names;
      ix = SecondaryIndex.emptyWith<Nat>(indexes, composites);
      rix = RegionIndex.empty();
    };
  };

  // ── Value ⇄ Cell (the single place the columnar mapping lives; widen here
  //    when the store grows more cell types) ──────────────────────────────────
  // Numeric cells are fixed 64-bit: a `#nat` must be < 2^64 and an `#int` must
  // fit `Int64`; a larger value traps here (the heap `IndexedMap` has no such
  // cap). Use a heap backend for values outside the 64-bit range.
  func valueToCell(v : Value) : ?Cell.Cell = switch v {
    case (#null_)   null;
    case (#bool b)  ?#bool b;
    case (#nat n)   ?#nat(Nat64.fromNat(n));
    case (#int i)   ?#int(Int64.fromInt(i));
    case (#float f) ?#float f;
    case (#text t)  ?#text t;
  };
  func cellToValue(c : ?Cell.Cell) : Value = switch c {
    case (null)      #null_;
    case (?#nat n)   #nat(n.toNat());
    case (?#int i)   #int(i.toInt());
    case (?#float f) #float f;
    case (?#bool b)  #bool b;
    case (?#text t)  #text t;
    // Unreachable: every row/served path skips #bytes columns (they are opaque
    // to the query layer and read through `bytesRuns` instead). Loud if not.
    case (?#bytes _) Runtime.trap("Table: a #bytes cell has no query-layer Value");
  };

  // Read-side counterpart of `valueToCell` for zone-map bound extraction. Unlike
  // `valueToCell` it is TOTAL — it never traps — returning null for any value
  // that can't be a fixed-width cell bound: a numeric outside the 64-bit range.
  // A null bound simply means "no zone-map pruning from this value", so the scan
  // stays a correct superset instead of the query trapping at plan time.
  // `valueToCell` keeps trapping on the WRITE path, where an unstorable value
  // must fail loudly rather than be silently dropped.
  func valueToBound(v : Value) : ?Cell.Cell = switch v {
    case (#null_)   null;
    case (#bool b)  ?#bool b;
    case (#nat n)   if (n <= 18_446_744_073_709_551_615) ?#nat(Nat64.fromNat n) else null;
    case (#int i)   if (i >= -9_223_372_036_854_775_808 and i <= 9_223_372_036_854_775_807) ?#int(Int64.fromInt i) else null;
    case (#float f) ?#float f;
    case (#text t)  ?#text t;
  };

  public func colTypeText(t : Cell.ColType) : Text = switch t { case (#nat) "#nat"; case (#int) "#int"; case (#float) "#float"; case (#bool) "#bool"; case (#text) "#text"; case (#bytes w) "#bytes(" # w.toText() # ")" };
  func cellKindText(c : Cell.Cell) : Text = switch c { case (#nat _) "#nat"; case (#int _) "#int"; case (#float _) "#float"; case (#bool _) "#bool"; case (#text _) "#text"; case (#bytes _) "#bytes" };
  // A cell's kind must equal its column's declared type. #nat/#int/#float share
  // an 8-byte slot but are stored by cell-kind and read back by column-type, so
  // a mismatch (e.g. a #nat value in a #float column) would bit-reinterpret the
  // data on read AND be dropped from the footer sum — silent corruption.
  func kindMatches(t : Cell.ColType, c : Cell.Cell) : Bool = switch (t, c) {
    case (#nat, #nat _) true; case (#int, #int _) true; case (#float, #float _) true;
    case (#bool, #bool _) true; case (#text, #text _) true;
    case (#bytes w, #bytes b) b.size() == w; case _ false;
  };

  // A `Row` may carry fields beyond the stored columns; only the declared
  // columns are stored, looked up by name. Each stored value must match its
  // column's declared type: a kind mismatch traps here (loudly, at append)
  // rather than silently reinterpreting the bytes and zeroing the column's sum.
  func rowToCells(names : [Text], cols : [Cell.ColType], row : Row) : [?Cell.Cell] =
    Array.tabulate<?Cell.Cell>(names.size(), func (i : Nat) : ?Cell.Cell {
      let name = names[i];
      var found : ?Value = null;
      for ((k, v) in row.values()) { if (k == name) found := ?v };
      switch found {
        case null null;                                  // absent field → null cell
        case (?v) switch (valueToCell(v)) {
          case null null;                                // #null_ → null cell, valid for any column
          case (?c) {
            if (not kindMatches(cols[i], c)) Runtime.trap(
              "Table.append: column \"" # name # "\" is declared " # colTypeText(cols[i])
              # " but the row's value is " # cellKindText(c) # " — declare the column to match the field's value kind");
            ?c;
          };
        };
      };
    });

  // The stored columns as a `Row` (for index maintenance on delete). #bytes
  // columns are skipped: they have no query-layer Value and are never indexed.
  func dataRow(names : [Text], cols : [Cell.ColType], cells : [?Cell.Cell]) : Row {
    let out = List.empty<(Text, Value)>();
    for (i in names.keys()) {
      if (Cell.bytesWidth(cols[i]) == null) out.add((names[i], cellToValue(cells[i])));
    };
    out.toArray();
  };

  // Footer-served sum of column `col`, returning EXACTLY the Value a scan-fold
  // would (so served == scanned). Integer columns (#nat/#int) sum exactly (the
  // running total is an arbitrary-precision Int), so they are served flat: #nat
  // to #nat, #int to #int. A #float column is NOT served — an incrementally
  // maintained float sum can diverge from a fold (precision lost at add-time
  // can't be recovered when a value is deleted, and per-segment grouping isn't
  // associative), so it returns null and the executor scan-folds for exactness.
  // An empty/all-null column returns #nat(0) to match the scan's #nat(0) seed.
  // #bool and unknown columns (e.g. the position PK) return null → scan.
  func colSum(self : Table, col : Text) : ?Value {
    switch (colIndexOf(self.names, col)) {
      case null null;
      case (?j) switch (self.store.cols[j], self.store.sumOf(j)) {
        // A #nat column needs no live-count probe: an empty column's running sum
        // is 0 and the scan-fold seeds #nat(0), so both answers are #nat(0).
        case (#nat, #int s) ?#nat(Int.abs(s));
        // An #int column summing to exactly 0 is the one ambiguous case — empty
        // (the scan seeds #nat(0)) or real values cancelling (the scan promotes
        // to #int(0)) — so pay for the live count only there.
        case (#int, #int s) {
          if (s == 0 and self.store.countOf(j) == 0) ?#nat(0) else ?#int(s);
        };
        // #float never serves (an incrementally maintained float sum can diverge
        // from a fold); #bool/#text and an empty column of those fall to the
        // scan, which yields the same #nat(0).
        case _              null;
      };
    };
  };

  // Footer-served avg = sum / non-null count, as the scan-fold gives it: a
  // #float, or #null_ for an empty/all-null column. Only integer columns are
  // served (their sum is exact); a #float column returns null and is scan-folded
  // for exactness — the maintained float sum can diverge from a fold (see
  // colSum). #bool and unknown columns also return null → scan. Matches
  // Executor.avgOf.
  func colAvg(self : Table, col : Text) : ?Value {
    switch (colIndexOf(self.names, col)) {
      case (?j) {
        let s : Float = switch (self.store.cols[j], self.store.sumOf(j)) {
          case (#nat, #int x)   Float.fromInt(x);
          case (#int, #int x)   Float.fromInt(x);
          case _                return null;  // #float / #bool / unexpected → scan
        };
        let cnt = self.store.countOf(j);
        if (cnt == 0) ?#null_ else ?#float(s / Float.fromInt(cnt));
      };
      case null null;
    };
  };

  func colIndexOf(names : [Text], name : Text) : ?Nat {
    var i = 0;
    for (n in names.values()) { if (n == name) return ?i; i += 1 };
    null;
  };
  // A #bytes column is opaque — no order, no postings — so it cannot be indexed.
  func requireIndexable(names : [Text], cols : [Cell.ColType], col : Text) {
    let ?i = colIndexOf(names, col) else Runtime.trap("Table.new: column \"" # col # "\" is indexed but not one of the table's columns");
    if (Cell.bytesWidth(cols[i]) != null) Runtime.trap("Table: column \"" # col # "\" is #bytes and cannot be indexed");
  };
  func path1(pt : [Text]) : ?Text = if (pt.size() == 1) ?pt[0] else null;
  func loMax(a : ?Cell.Cell, b : ?Cell.Cell) : ?Cell.Cell = switch (a, b) { case (null, x) x; case (x, null) x; case (?x, ?y) if (Cell.lt(x, y)) ?y else ?x };
  func hiMin(a : ?Cell.Cell, b : ?Cell.Cell) : ?Cell.Cell = switch (a, b) { case (null, x) x; case (x, null) x; case (?x, ?y) if (Cell.lt(x, y)) ?x else ?y };

  // Extract a single-column [lo, hi] zone-map constraint from the query
  // predicate (flattening top-level `#and_`): the first stored column with an
  // eq/range conjunct, with its bounds combined across conjuncts. Returns
  // (columnIndex?, lo?, hi?) in cell terms. A superset is always safe — the
  // executor re-applies the full predicate — so anything not extractable
  // (or/not, multi-column paths, `#ne`) simply yields no bound (full scan).
  func rangeConstraint(names : [Text], where_ : ?Predicate.Predicate) : (?Nat, ?Cell.Cell, ?Cell.Cell) {
    let cs = List.empty<Predicate.Predicate>();
    func go(p : Predicate.Predicate) = switch p { case (#and_ ps) { for (x in ps.values()) go(x) }; case _ cs.add(p) };
    switch where_ { case (?p) go(p); case null {} };
    var target : ?Text = null;
    for (p in cs.values()) {
      let nm = switch p {
        case (#eq(pt, _)) path1(pt); case (#lt(pt, _)) path1(pt); case (#le(pt, _)) path1(pt);
        case (#gt(pt, _)) path1(pt); case (#ge(pt, _)) path1(pt); case _ null;
      };
      switch nm { case (?n) { switch (colIndexOf(names, n)) { case (?_) { target := ?n; break }; case null {} } }; case null {} };
    };
    switch target {
      case null (null, null, null);
      case (?tname) {
        var lo : ?Cell.Cell = null;
        var hi : ?Cell.Cell = null;
        for (p in cs.values()) {
          switch p {
            case (#eq(pt, v)) { if (path1(pt) == ?tname) { let c = valueToBound(v); lo := loMax(lo, c); hi := hiMin(hi, c) } };
            case (#ge(pt, v)) { if (path1(pt) == ?tname) lo := loMax(lo, valueToBound(v)) };
            case (#gt(pt, v)) { if (path1(pt) == ?tname) lo := loMax(lo, valueToBound(v)) };
            case (#le(pt, v)) { if (path1(pt) == ?tname) hi := hiMin(hi, valueToBound(v)) };
            case (#lt(pt, v)) { if (path1(pt) == ?tname) hi := hiMin(hi, valueToBound(v)) };
            case _ {};
          };
        };
        (colIndexOf(names, tname), lo, hi);
      };
    };
  };

  // The full served row: the store position under `pk`, then the stored columns.
  // #bytes columns are skipped — invisible to schema, projection and predicates
  // alike (the same absence mechanism as `.hidden`); read them via `bytesRuns`.
  func fullRow(names : [Text], cols : [Cell.ColType], pk : Text, pos : Nat, cells : [?Cell.Cell]) : Row {
    let out = List.empty<(Text, Value)>();
    out.add((pk, #nat(pos)));
    for (i in names.keys()) {
      if (Cell.bytesWidth(cols[i]) == null) out.add((names[i], cellToValue(cells[i])));
    };
    out.toArray();
  };

  // ── writes ─────────────────────────────────────────────────────────────────

  /// Append a row; returns its store position (the primary key). `_toRow`
  /// derives from `V` (implicit) — its output feeds both the index postings and
  /// the stored cells (only the declared columns are kept). The row buffers and
  /// auto-flushes into a segment when the buffer fills.
  public func append<V>(self : Table, v : V, _toRow : (implicit : V -> Row)) : Nat {
    // A position that enters any way but a segment while a column is mid-extension shifts
    // every later row against its posting, and the commit arithmetic — which only counts —
    // would still balance and flip the column ready over a base that describes the wrong
    // rows. Refuse until the extension finishes or its segments are dropped.
    if (RegionIndex.anyReopened(self.rix)) Runtime.trap(
      "Table.append: an index is mid-extension — finish the load, or drop what is staged, before appending");
    let row = _toRow(v);
    let pos = self.store.append(rowToCells(self.names, self.store.cols, row));
    SecondaryIndex.onChange<Nat>(self.ix, Nat.compare, pos, null, ?row);
    pos;
  };

  /// `append` for a row that also carries `#bytes` cells, which a query-layer
  /// `Row` cannot express: `bytes` names each #bytes column's cell for this row
  /// (an unnamed #bytes column stays null). Traps on a width mismatch or a
  /// non-#bytes column named in `bytes`.
  public func appendWithBytes<V>(self : Table, v : V, _toRow : (implicit : V -> Row), bytes : [(Text, Blob)]) : Nat {
    if (RegionIndex.anyReopened(self.rix)) Runtime.trap(
      "Table.append: an index is mid-extension — finish the load, or drop what is staged, before appending");
    let row = _toRow(v);
    let cells = (rowToCells(self.names, self.store.cols, row)).toVarArray<?Cell.Cell>();
    for ((name, b) in bytes.values()) {
      let ?i = colIndexOf(self.names, name) else Runtime.trap("Table.appendWithBytes: \"" # name # "\" is not a stored column");
      let ?w = Cell.bytesWidth(self.store.cols[i]) else Runtime.trap("Table.appendWithBytes: column \"" # name # "\" is not #bytes");
      if (b.size() != w) Runtime.trap("Table.appendWithBytes: column \"" # name # "\" is #bytes(" # w.toText() # ") but the cell is " # b.size().toText() # " bytes");
      cells[i] := ?#bytes(b);
    };
    let pos = self.store.append(Array.fromVarArray<?Cell.Cell>(cells));
    SecondaryIndex.onChange<Nat>(self.ix, Nat.compare, pos, null, ?row);
    pos;
  };

  /// Iterate a `#bytes` column as raw runs — one per flushed segment (pointing
  /// straight into the Region) plus one for a non-empty write buffer — for an
  /// app-level scan such as vector search. See `Columnar.BytesRun` for the run
  /// shape and the liveness contract. APP-LEVEL ONLY: this bypasses `execute()`
  /// and with it all per-caller scoping — never expose it to untrusted callers.
  /// Traps if `col` is not a stored `#bytes` column.
  public func bytesRuns(self : Table, col : Text) : Iter.Iter<Columnar.BytesRun> {
    let ?ci = colIndexOf(self.names, col) else Runtime.trap("Table.bytesRuns: \"" # col # "\" is not a stored column");
    self.store.bytesRuns(ci);
  };

  /// Logically delete the row at `pos`, dropping its postings from every index.
  /// A row loaded before a region index committed (position `< base.rows`) is
  /// not in the heap delta; `RegionIndex.onDelete` records it in the base's DEAD
  /// bitmap instead, so `count`/`point` over the base stay exact.
  public func delete(self : Table, pos : Nat) {
    let cells = self.store.getRow(pos);
    let old = cells.map<[?Cell.Cell], Row>(func (cs) = dataRow(self.names, self.store.cols, cs));
    SecondaryIndex.onChange<Nat>(self.ix, Nat.compare, pos, old, null);
    switch cells { case (?cs) RegionIndex.onDelete(self.rix, pos, cs); case null {} };
    self.store.delete(pos);
  };

  /// Flush the write buffer into an immutable segment, moving those rows off the
  /// heap into the Region. Auto-flush handles the steady state; call this to
  /// force the trailing partial buffer.
  public func flush(self : Table) = self.store.flush();

  /// Live row count.
  public func size(self : Table) : Nat = self.store.count();

  /// The underlying store — advanced / measurement use (e.g. `Region` size).
  public func store(self : Table) : Columnar.State = self.store;

  // ── bulk load ───────────────────────────────────────────────────────────

  /// A table named for bulk loading, as the `ImportData` mixin takes it. Carries
  /// the table itself rather than closures over it — a `Table` is pure data, so
  /// the mixin operates on the value directly and stores nothing.
  public type ImportTarget = { name : Text; table : Table };

  /// A target's physical column list, in storage order: what a producer needs to
  /// lay a segment image out. The canister is the authority on names and types; a
  /// producer maps its source onto this and declares neither.
  public type Layout = {
    columns : [{ name : Text; colType : Text }];
  };

  /// Name this table for bulk loading — the write-side counterpart of `entity`.
  public func importTarget(self : Table, name : Text) : ImportTarget = { name; table = self };

  /// Total rows ever appended, tombstones INCLUDED — the store position the next
  /// appended row or loaded segment will occupy. The bulk-load protocol keys on
  /// this, never on `size`: positions are dense and never reused, so a table that
  /// has had deletes has `appended > size`. Using `size` as the resume cursor
  /// would undercount the source rows already consumed and re-send the
  /// difference as duplicates.
  public func appended(self : Table) : Nat = self.store.watermark + self.store.buffer.size();

  /// Positions that arrived as a SEGMENT IMAGE, as opposed to `append`. This is the
  /// producer's FILE cursor; `appended` is the table's POSITION cursor. They are the
  /// same number only while every row came from the file, in order — one ordinary write
  /// and they part company for good, by exactly the number of such writes.
  ///
  /// A producer needs BOTH and for different things: it resumes reading its file at
  /// this, and labels the segment it then sends with `appended`. Using one number for
  /// both is what skips a source row and lands every later one a position high.
  public func loadedRows(self : Table) : Nat = self.store.imageRows();

  /// Whether `col`'s region index is complete (see `RegionIndex.isReady`). `null` when
  /// `col` is not a stored column, so a caller can tell that apart from "not ready".
  public func indexReady(self : Table, col : Text) : ?Bool =
    switch (colIndexOf(self.names, col)) {
      case (?ci) ?RegionIndex.isReady(self.rix, ci);
      case null null;
    };

  /// `col`'s region index as a producer needs to see it: complete, a first upload that
  /// never finished, one reopened for an extension, or absent. `null` when `col` is not a
  /// stored column.
  public func indexState(self : Table, col : Text) : ?RegionIndex.ProducerState =
    switch (colIndexOf(self.names, col)) {
      case (?ci) ?RegionIndex.stateOf(self.rix, ci);
      case null null;
    };

  /// Load a pre-built segment image (see `columnar/Image`) into the table,
  /// returning the first row-id it occupies.
  ///
  /// Traps if the table declares any secondary index. An image load adds no
  /// postings, and an index declared at construction is already marked ready —
  /// the planner would keep routing queries to it while it misses every loaded
  /// row, a silent under-fetch. Bulk-load an index-free table; building indexes
  /// over the loaded segments is its own job. To load MORE data into a table whose
  /// region indexes are already committed, `reopenIndex` every one of those columns
  /// first: that is what drops their decls, and this same gate is what enforces it
  /// — a column left ready would keep serving a base missing every new row.
  public func loadSegment(self : Table, image : Blob) : Nat {
    if (self.ix.decls.size() > 0 or self.ix.decls2.size() > 0) Runtime.trap(
      "Table.loadSegment: this table declares secondary indexes, which a segment image does not maintain — bulk-load an index-free table, or reopenIndex every region-indexed column first");
    // Every position must have arrived as an image, or the producer's two cursors have
    // already drifted apart. It resumes its FILE read from the table's ROW COUNT, and
    // labels each index segment with a POSITION — the same number, and correct only
    // while every row came from the file in order. One ordinary append breaks that:
    //
    //   file  [A,B,C]      -> positions 0,1,2      append X -> position 3
    //   file grows to [A,B,C,D,E]: the load skips 4 file rows (the row count) and sends
    //   only E, so D is never loaded and the table is [A,B,C,X,E]. The index then
    //   resumes from its coverage and maps [B,C,D,E] onto positions 1..4 — claiming
    //   position 3 holds D when it holds X. Coverage and row count both reach 5, so the
    //   column goes READY misaligned: `eq X` misses, and counts report D.
    //
    // Nothing downstream can catch that — the arithmetic balances, which is the same
    // reason the reopen path needs its own guard. Refuse the load instead, at the
    // moment the drift would first matter.
    requireAppendsIndexed(self, "loadSegment");
    self.store.appendSegmentImage(image);
  };

  /// `loadSegment` for an image whose rows begin at `firstRow`. Equal to the current
  /// position count it lands directly; ahead of it the segment is held until the gap
  /// fills, so a producer can keep several images in flight and let arrival order be
  /// whatever the network makes it. Returns the image's row count — landing one segment
  /// can promote several staged ones, so the position count is not a per-call answer.
  public func loadSegmentAt(self : Table, image : Blob, firstRow : Nat) : Nat {
    if (self.ix.decls.size() > 0 or self.ix.decls2.size() > 0) Runtime.trap(
      "Table.loadSegmentAt: this table declares secondary indexes, which a segment image does not maintain — bulk-load an index-free table, or reopenIndex every region-indexed column first");
    // Every position must have arrived as an image, or the producer's two cursors have
    // already drifted apart. It resumes its FILE read from the table's ROW COUNT, and
    // labels each index segment with a POSITION — the same number, and correct only
    // while every row came from the file in order. One ordinary append breaks that:
    //
    //   file  [A,B,C]      -> positions 0,1,2      append X -> position 3
    //   file grows to [A,B,C,D,E]: the load skips 4 file rows (the row count) and sends
    //   only E, so D is never loaded and the table is [A,B,C,X,E]. The index then
    //   resumes from its coverage and maps [B,C,D,E] onto positions 1..4 — claiming
    //   position 3 holds D when it holds X. Coverage and row count both reach 5, so the
    //   column goes READY misaligned: `eq X` misses, and counts report D.
    //
    // Nothing downstream can catch that — the arithmetic balances, which is the same
    // reason the reopen path needs its own guard. Refuse the load instead, at the
    // moment the drift would first matter.
    requireAppendsIndexed(self, "loadSegmentAt");
    self.store.appendSegmentImageAt(image, firstRow);
  };

  /// Segments held waiting on a gap. A load is finished when this is 0.
  public func stagedSegments(self : Table) : Nat = self.store.stagedCount();

  /// Drop every segment still waiting on a gap, returning how many. This is the recovery
  /// path for a load that stopped mid-flight: the rows those segments carried were never
  /// counted, so a producer clears them and resumes from `appended`.
  public func dropStagedSegments(self : Table) : Nat = self.store.dropStaged();

  public func layoutOf(t : ImportTarget) : Layout = {
    columns = Array.tabulate<{ name : Text; colType : Text }>(t.table.names.size(), func (i : Nat) =
      { name = t.table.names[i]; colType = colTypeText(t.table.store.cols[i]) });
  };

  // ── region index: upload + commit ─────────────────────────────────────────

  /// Accept one ordered chunk of a pre-built index SEGMENT for `col`, covering the
  /// store positions `[firstRow, …)` (see `RegionIndex.putChunk`): the producer
  /// builds one segment at a time and uploads it after the data, in order, with an
  /// expect-offset guard. The segment is not servable until the column's segments
  /// tile `[0, appended)` (see `commitIndex`). Traps unless `col` is a stored
  /// column.
  public func putIndexChunk(self : Table, col : Text, kind : Kind, firstRow : Nat, segLen : Nat, expectOffset : Nat, chunk : Blob) : Nat {
    let ?ci = colIndexOf(self.names, col) else Runtime.trap("Table.putIndexChunk: \"" # col # "\" is not a stored column");
    switch (Cell.bytesWidth(self.store.cols[ci])) {
      case (?_) Runtime.trap("Table.putIndexChunk: \"" # col # "\" is #bytes and cannot be indexed");
      case null {};
    };
    RegionIndex.putChunk(self.rix, ci, kind, self.store.cols[ci], firstRow, segLen, expectOffset, chunk);
  };

  /// Discard an in-flight index-segment upload, freeing its staged block. A
  /// producer that fails part-way through a segment leaves the table unable to
  /// stage another or commit the partial one; this clears it so the load can be
  /// retried. Returns whether there was an upload to discard.
  public func abortIndexUpload(self : Table) : Bool = RegionIndex.abortUpload(self.rix);

  /// Commit the staged segment onto `col`'s base. When the committed segments tile
  /// `[0, appended)` exactly, the column becomes servable: this declares the heap
  /// DELTA for `col` and marks it ready (the base covers `[0, appended)`, the delta
  /// covers writes after commit — nothing to backfill), and `onChange` maintains
  /// the delta from here. Until the tiling is complete the column stays unindexed
  /// and its queries pay for the uncovered tail, so a row appended between load and
  /// commit — which the last segment would leave uncovered — is never an
  /// under-fetch. Traps on a gap/overlap or a segment reaching past `appended`
  /// (the coverage guard). Returns the segment's row count.
  ///
  /// A column REOPENED for extension takes this path again verbatim: it is pending,
  /// so its segments continue from `indexCoverage` under the same tiling rule, and
  /// the ready branch re-declares a delta that `reopenIndex` removed — which is why
  /// `addDecl` does not see a duplicate.
  public func commitIndex(self : Table, col : Text) : Nat {
    let ?ci = colIndexOf(self.names, col) else Runtime.trap("Table.commitIndex: \"" # col # "\" is not a stored column");
    // The other direction of the overlap `addIndex` refuses. A heap index over this
    // column already answers for every row; a region base would answer for the prefix
    // it covers as well, and the two are concatenated without dedup — every covered row
    // returned twice and counted twice. The COMPLETING commit is caught anyway, by
    // `addDecl` refusing a second decl below, but a PARTIAL one calls nothing and would
    // leave exactly that state serving. A pending heap build counts too: its walk ends
    // in the same place. Checked before the commit, so nothing is written.
    if (hasDecl(self.ix, col)) Runtime.trap(
      "Table.commitIndex: \"" # col # "\" already has a heap index over the same rows — a region base would double every row it covers");
    let r = RegionIndex.commit(self.rix, ci, appended(self));
    // Fold tombstones for the rows this commit just brought under the base. A row
    // deleted while its position was still past `coveredEnd` set no DEAD bit — no
    // segment owned it — and the segment now covering it arrived with a clean bitmap,
    // so the base would count it live. `count` is run arithmetic and never consults
    // the store to notice.
    //
    // This runs on EVERY commit, not only the one that completes the tiling. It used to
    // be enough to do it at the end, because a base that did not yet cover everything
    // was never read; now the covered prefix answers queries, so a deleted row left
    // live is a wrong answer from the next commit onward rather than at the end.
    // Idempotent — `setDead` reports whether it flipped the bit — and `onDelete`
    // ignores positions still outside the base, so a tombstone above the frontier waits
    // for the commit that covers it.
    for (pos in self.store.deletedPositions()) {
      switch (self.store.rawRow(pos)) {
        case (?cs) RegionIndex.onDelete(self.rix, pos, cs);
        case null {};
      };
    };
    if (r.ready) {
      // Going ready means the base now covers every position, buffered rows included —
      // and a DELETED buffered row is a hole in the buffer: not in the store's
      // tombstone set, and its cells are gone, so the fold below can neither see it nor
      // read it and its posting would count as live for the life of the index. Trapping
      // rolls this commit back; flush first and the rows become foldable segment rows.
      // A commit that leaves coverage SHORT is unaffected — the column stays pending
      // and queries scan, which is a correct superset.
      if (self.store.buffer.size() > 0)
        Runtime.trap("Table.commitIndex: the index would serve " # self.store.buffer.size().toText() # " unflushed buffered row(s) — flush before the commit that completes it");
      // `appended` is the CONTIGUOUS frontier, so it does not count rows in segments still
      // waiting on a gap. Going ready against it would declare the column complete over a
      // table that is short: when those segments are later promoted their rows are in
      // neither base nor delta, which is a silent under-fetch. An interrupted load that
      // left segments staged must either finish or drop them first.
      if (self.store.stagedCount() > 0)
        Runtime.trap("Table.commitIndex: " # self.store.stagedCount().toText() # " segment(s) are staged ahead of row " # appended(self).toText() # " — finish or drop them before completing an index");
      SecondaryIndex.addDecl<Nat>(self.ix, #col col, r.kind);
      SecondaryIndex.markReady<Nat>(self.ix, #col col);
    };
    r.rows;
  };

  /// Reopen `col`'s committed region index for extension (`RegionIndex.reopen`), and
  /// drop its heap decl. The column keeps answering for the whole window: its base
  /// still covers `[0, coveredEnd)` and serves that prefix, and only the rows past it
  /// are scanned. `min`/`max` are unaffected: they come from the store's
  /// segment footers, never from an index. Dropping the decl is also what re-satisfies
  /// `loadSegment`'s precondition, which is what forces every indexed column to be
  /// reopened before the load rather than one of them left serving a short base.
  ///
  /// Returns false, changing nothing, when `col` has no committed region index or is
  /// already reopened. Traps when rows were appended since the column went ready.
  public func reopenIndex(self : Table, col : Text) : Reopen {
    let ?ci = colIndexOf(self.names, col) else Runtime.trap("Table.reopenIndex: \"" # col # "\" is not a stored column");
    let left = absorbAppended(self, ci, col);
    if (left > 0) return #absorbing left;
    if (not RegionIndex.reopen(self.rix, ci, appended(self))) return #none;
    // `reopen`'s `coveredEnd == appended` already implies the delta is empty: the
    // base covers every position, and the only delta writer is `onChange` on append,
    // which names the position it has just allocated. This tests that conclusion
    // DIRECTLY, so the guard does not rest on there being no update path — a writer
    // that named a base position in the delta would otherwise have its live postings
    // discarded below. A trap rolls the whole message back, `reopen` included.
    if (hasPostings(self.ix, col)) Runtime.trap(
      "Table.reopenIndex: the heap delta still holds postings for \"" # col # "\" — reopening would discard them");
    removeDecl(self.ix, col);
    #reopened;
  };

  /// What one `reopenIndex` call achieved. `#absorbing n` means the canister indexed a
  /// chunk of its own appended rows and `n` remain — CALL AGAIN. The cursor is the
  /// column's coverage, which is durable and is the same cursor an interrupted upload
  /// resumes from, so there is no progress state to keep and no timer to lose: the
  /// producer drives this the way it drives every other step.
  public type Reopen = { #reopened; #absorbing : Nat; #none };

  // Bring the rows appended since the last commit into `col`'s base, so the base covers
  // every position again and an extension can continue from a single frontier.
  //
  // These rows are the reason a bulk-loaded table used to be loadable only once. They
  // are in the heap delta at positions past `coveredEnd`, and no producer can supply a
  // segment for them: they were never in a file. Extending over them would need the base
  // to tile around a hole — a range list instead of one cursor, and the end of the guard
  // that has caught most of the real bugs here.
  //
  // So the canister builds that segment itself, from its OWN rows, with the same builder
  // the producer uses and through the same validated commit path. The gap closes, the
  // base covers `[0, appended)`, and `reopen` then applies unchanged. Cost is O(rows
  // appended since the last commit) in one message — the writes a live canister took
  // between two ingests, not anything sized by the table.
  //
  // The delta postings for those rows go with the decl: they are in the base now, so
  // dropping them is what keeps every position in exactly one half.
  //
  // A no-op unless `col` is ready with a gap, which is the only state that needs it.
  func absorbAppended(self : Table, ci : Nat, col : Text) : Nat {
    if (self.store.buffer.size() > 0) self.store.flush();
    let to = appended(self);
    let ?start = RegionIndex.beginAbsorb(self.rix, ci, to) else return 0;
    let keyType = self.store.cols[ci];
    // In CHUNKS, for the same reason the producer uploads in chunks: the builder groups
    // positions by key on the GC heap, so one segment over the whole gap would put O(gap)
    // there — and the gap is however many rows the application appended since the last
    // ingest, which is unbounded and is exactly what the rest of this design refuses to
    // be sized by. Segments only have to tile contiguously and ascending, so several
    // small ones are as valid as one large one; peak heap becomes one chunk.
    // ONE chunk per call. The gap is however many rows the application wrote since the
    // last ingest — days of traffic, not a batch — and the builder groups positions by
    // key on the GC heap, so the whole gap in one message would put O(gap) there and
    // could exhaust the message besides. The caller repeats until `#reopened`.
    let n = Nat.min(absorbSeg(self), to - start);
    let scratch = Region.new();
    // `rawRow`, not `getCell`: `getCell` reports a DELETED row as a null cell, which
    // would file it under the null run — and the DEAD fold below probes with the row's
    // REAL key, finds no posting there, and leaves it live. The deleted row would then
    // answer `eq(col, null)` forever. The raw cell puts it in its real key's run, where
    // the fold can find it and kill it.
    let bytes = HashSegment.build(scratch, keyType, start, n,
      func (local : Nat) : ?Cell.Cell =
        switch (self.store.rawRow(start + local)) { case (?cs) cs[ci]; case null null });
    ignore RegionIndex.putChunk(self.rix, ci, #hash, keyType, start, bytes.size(), 0, bytes);
    ignore RegionIndex.commit(self.rix, ci, to);
    // Same fold `commitIndex` does: a row deleted while its position was past the
    // frontier set no DEAD bit, and this segment arrived with a clean bitmap.
    for (pos in self.store.deletedPositions()) {
      switch (self.store.rawRow(pos)) {
        case (?cs) RegionIndex.onDelete(self.rix, pos, cs);
        case null {};
      };
    };
    removeDecl(self.ix, col);
    to - (start + n);
  };

  // The inverse of `SecondaryIndex.addDecl` for a single column: the decl, its
  // posting store, and any pending mark. The STORE matters as much as the decl —
  // every accessor gates on `byCol.get`, so a column left with an emptied store
  // would answer `count` 0 instead of falling back to the scan.
  func removeDecl(ix : SecondaryIndex.Index<Nat>, col : Text) {
    ix.decls := ix.decls.filter(func ((c, _) : (Text, Kind)) : Bool = c != col);
    ignore ix.byCol.delete(Text.compare, col);
    ignore ix.pending.delete(Text.compare, col);
  };

  // Whether `col` carries a heap index DECL — ready or still backfilling. Distinct
  // from `hasPostings`: a decl with an empty posting store still routes queries.
  func hasDecl(ix : SecondaryIndex.Index<Nat>, col : Text) : Bool {
    for ((c, _) in ix.decls.values()) { if (c == col) return true };
    false;
  };

  // Whether the heap delta holds any posting for `col`. One map descent, not a
  // size fold: the question is emptiness, and the store can hold O(distinct keys).
  func hasPostings(ix : SecondaryIndex.Index<Nat>, col : Text) : Bool =
    switch (ix.byCol.get(Text.compare, col)) {
      case (?ci) Option.isSome(ci.entries().next());
      case null false;
    };

  // Every position that arrived by `append` must already be in every region index's
  // base before more rows are loaded.
  //
  // The DATA side is safe on its own: the producer places each image at `rows()`, the
  // position cursor, and reads its file from `loadedRows`, so records land where they
  // are said to land. What is not safe is the INDEX. An index segment is built from
  // file records and labelled with a position, and if an appended row sits at or above
  // the base's frontier, the next segment claims that position while holding a record
  // that belongs elsewhere — `eq` then misses the appended row and reports the file's
  // value instead. The counts still balance, so nothing downstream notices.
  //
  // `reopenIndex` clears this by absorbing the appended rows into the base, which is
  // why a delta load into a ready column just works. What it refuses is the case with
  // no way out: appends made while an index was still being uploaded for the first
  // time, and appends on a table that has no region index yet, where the index built
  // later would be misaligned from the start.
  func requireAppendsIndexed(self : Table, what : Text) {
    let mark = self.store.lastAppendEnd();
    if (mark == 0) return;
    // A DROPPED entry keeps its directory slot but covers nothing, and it is not an index —
    // `indexState` reports it as none. Counting its zero coverage here would reject every
    // later load for an index that no longer exists. It does not satisfy the invariant
    // either: a table whose only entries are dropped is the no-index case, which is refused
    // for its own reason — an index built from the file afterwards would be misaligned from
    // the start.
    var real = 0;
    var short = false;
    for (e in self.rix.entries.values()) {
      if (e.coveredEnd > 0) {
        real += 1;
        if (e.coveredEnd < mark) short := true;
      };
    };
    if (real == 0) short := true;
    if (short) Runtime.trap(
      "Table." # what # ": rows up to " # mark.toText()
      # " were appended rather than loaded and are not yet in every index's base — reopenIndex the region-indexed columns first, so those rows are absorbed before more are loaded");
  };

  /// Discard `col`'s committed region base and its heap decl, leaving the column
  /// unindexed — queries scan, which is correct, just slower.
  ///
  /// The recovery path for a base that can never be finished. A first index upload that
  /// committed some segments and was then overtaken by ordinary writes is the case that
  /// needs it: the file cannot describe the positions the remaining segments would claim,
  /// so the off-chain path is closed for good, and `addIndex` needs the column clear before
  /// it can build on-chain instead. `abortIndexUpload` is not that — it drops the segment
  /// in flight, never one already committed.
  ///
  /// The decl goes too. A ready column's decl carries only the delta, so leaving it behind
  /// would point the planner at a heap index holding a fraction of the rows — an
  /// under-fetch, where scanning is merely slow.
  ///
  /// Returns false, changing nothing, when `col` has no region base.
  public func dropIndexBase(self : Table, col : Text, expectCoveredEnd : Nat) : Bool {
    let ?ci = colIndexOf(self.names, col) else Runtime.trap("Table.dropIndexBase: \"" # col # "\" is not a stored column");
    let covered = RegionIndex.coveredTo(self.rix, ci);
    // Nothing to drop: answer before touching anything. Aborting staging first — which is
    // what this did — meant a retry after the replacement upload had already begun
    // discarded that upload's bytes and still reported "changing nothing".
    if (covered == 0) return false;
    // Drop exactly the base the caller looked at. Coverage alone cannot distinguish "the
    // base I decided to discard" from "a replacement that has since committed over the
    // same column", so a delayed or duplicated retry would delete the replacement. The
    // caller passes the coverage it read; a mismatch means the world moved and the drop is
    // refused rather than applied to something else. Not a generation token, so it does not
    // separate a replacement that happens to reach the SAME coverage — that would need a
    // counter in the entry, which its 64-byte layout would have to grow a field for. The
    // tool never retries a drop; this closes the case an operator can reach by hand.
    if (covered != expectCoveredEnd) Runtime.trap(
      "Table.dropIndexBase: \"" # col # "\" covers " # covered.toText() # " row(s), not the "
      # expectCoveredEnd.toText() # " this drop was for — read indexCoverage again and retry if you still mean to");
    if (RegionIndex.stagingCol(self.rix) == ?ci) ignore RegionIndex.abortUpload(self.rix);
    if (not RegionIndex.dropBase(self.rix, ci)) return false;
    removeDecl(self.ix, col);
    true;
  };

  // ── adding an index later (over loaded/appended rows) ────────────────────

  /// One in-flight index build: the decl it fills, the next store position to
  /// walk, and completion. Pure data, so a driver MAY persist it to resume across
  /// an upgrade — though the `ImportData` mixin instead holds it transiently and
  /// restarts from the cursor's origin, since the decl's pending/ready state (the
  /// part correctness rests on) lives in the index and the walk is idempotent.
  public type IndexBuild = {
    target : SecondaryIndex.Target;
    var next : Nat;
    var done : Bool;
  };

  /// Declare a NEW single-column index over existing rows — the way an index
  /// reaches a bulk-loaded table, since `loadSegment` refuses a table that
  /// already declares one. The decl registers now (every subsequent write
  /// maintains it) but the column stays UNINDEXED to the planner until the
  /// returned build completes: drive `buildStep` until it reports done. Never a
  /// partial serve — mid-build, a query on `col` scans, exactly as before the
  /// call. Traps if `col` is already declared or not a stored column.
  public func addIndex(self : Table, col : Text, kind : Kind) : IndexBuild {
    requireIndexable(self.names, self.store.cols, col);
    // A region base on this column, in ANY state, makes the two halves overlap. A READY
    // one is caught by `addDecl` below, which refuses a second decl — but a base still
    // being uploaded holds no decl yet, and it SERVES the prefix it covers. The heap
    // build would then walk every row while the base answers for its prefix, and the
    // two are concatenated without dedup: every covered row returned twice by `point`
    // and counted twice by `count`. Refuse while the upload is in flight; the column
    // gets its index when the upload completes.
    switch (colIndexOf(self.names, col)) {
      case (?ci) if (RegionIndex.coveredTo(self.rix, ci) > 0) Runtime.trap(
        "Table.addIndex: \"" # col # "\" has a region index covering " # RegionIndex.coveredTo(self.rix, ci).toText()
        # " row(s) — finish that upload, or discard it with dropIndexBase, rather than building a second index over the same rows");
      case null {};
    };
    SecondaryIndex.addDecl<Nat>(self.ix, #col col, kind);
    { target = #col col; var next = 0; var done = false };
  };

  /// `addIndex` for a composite declaration — the column list in KEY order, as
  /// `newWith`. The same readiness gate: the composite serves only once the
  /// returned build completes.
  public func addComposite(self : Table, cols : [Text], kind : Kind) : IndexBuild {
    for (col in cols.values()) requireIndexable(self.names, self.store.cols, col);
    SecondaryIndex.addDecl<Nat>(self.ix, #cols cols, kind);
    { target = #cols cols; var next = 0; var done = false };
  };

  /// Index up to `budgetRows` store positions from the cursor — within THIS
  /// call only — and report whether the build is complete (flipping the decl
  /// ready the moment it is). Call repeatedly until it returns `true`.
  ///
  /// The walk reads ONLY the indexed columns — never a full row — and works
  /// SEGMENT-WISE below the watermark: the owning segment is resolved once per
  /// run (`Columnar.colRun`), the indexed cells stream straight off the
  /// Region, and (key, position) pairs feed the index directly
  /// (`SecondaryIndex.runWriter`) — no row assembly, no by-name lookup. It
  /// CONVERGES with concurrent writes: a delete ahead of the cursor is a
  /// tombstone the walk skips; a delete behind it removes the posting through
  /// `onChange`, as on a ready index; an append lands past the cursor, is
  /// indexed by `onChange` at once, and may be walked again later —
  /// idempotent, a posting dedups adds. The bound is re-read every iteration,
  /// so rows appended mid-build are covered.
  public func buildStep(self : Table, st : IndexBuild, budgetRows : Nat) : Bool {
    if (st.done) return true;
    let cols = switch (st.target) { case (#col c) [c]; case (#cols cs) cs };
    let idxs = cols.map<Text, Nat>(func (c : Text) : Nat {
      let ?i = colIndexOf(self.names, c) else Runtime.trap("Table.buildStep: column \"" # c # "\" is not stored");   // unreachable: addIndex checked
      i;
    });
    var left = budgetRows;
    while (st.next < self.store.watermark + self.store.buffer.size()) {
      if (left == 0) return false;   // budget spent, rows remain — resume here next call
      if (st.next < self.store.watermark) {
        left -= buildRun(self, st, cols, idxs, left);
      } else {
        // A buffered row is row-major on the heap — the per-row path is cheap.
        switch (self.store.reader(st.next)) {
          case (?rd) {
            let row = Array.tabulate<(Text, Value)>(cols.size(), func (i : Nat) : (Text, Value) =
              (cols[i], cellToValue(rd(idxs[i]))));
            SecondaryIndex.indexOne<Nat>(self.ix, Nat.compare, st.next, row, st.target);
          };
          case null {};   // deleted — nothing to index
        };
        st.next += 1;
        left -= 1;
      };
    };
    st.done := true;
    SecondaryIndex.markReady<Nat>(self.ix, st.target);
    true;
  };

  // One flushed-segment run of the index-build walk, at most `budget`
  // positions: resolve the indexed columns' cell readers and the target's
  // posting store once, then stream (key, position) pairs straight into the
  // index — no row built, no by-name lookup, and (through the writer's memo)
  // one map descent per KEY RUN rather than per row. A tombstoned position is
  // skipped — the same convergence a null `reader` gives the buffered path.
  // Returns the positions consumed; a deleted position costs a budget step
  // exactly as it does there.
  func buildRun(self : Table, st : IndexBuild, cols : [Text], idxs : [Nat], budget : Nat) : Nat {
    let ?(segEnd, rd0) = self.store.colRun(idxs[0], st.next) else Runtime.trap("Table.buildStep: no segment owns position " # st.next.toText());   // unreachable: segments partition [0, watermark)
    let runEnd = Nat.min(segEnd, st.next + budget);
    let taken = runEnd - st.next;
    // Deletes cannot land mid-call, so one emptiness check serves the run.
    let tombstones = self.store.deleted.size() > 0;
    func live(pos : Nat) : Bool = not tombstones or not self.store.deleted.contains(pos);
    if (idxs.size() == 1) {
      let write = SecondaryIndex.runWriter<Nat>(self.ix, Nat.compare, cols[0]);
      var pos = st.next;
      while (pos < runEnd) {
        if (live(pos)) write(cellToValue(rd0(pos)), pos);
        pos += 1;
      };
    } else {
      let rds = Array.tabulate<Nat -> ?Cell.Cell>(idxs.size(), func (i : Nat) : (Nat -> ?Cell.Cell) {
        if (i == 0) return rd0;
        let ?r = self.store.colRun(idxs[i], st.next) else Runtime.trap("Table.buildStep: no segment owns position " # st.next.toText());   // unreachable, as above
        r.1;
      });
      let write = SecondaryIndex.runWriterSeq<Nat>(self.ix, Nat.compare, cols);
      var pos = st.next;
      while (pos < runEnd) {
        if (live(pos)) write(Array.tabulate<Value>(rds.size(), func (i : Nat) : Value = cellToValue(rds[i](pos))), pos);
        pos += 1;
      };
    };
    st.next := runEnd;
    taken;
  };

  // ── region index (base half of the base ∪ delta merge) ────────────────────

  // The exact integer a query value denotes, or null when it denotes none — a
  // non-numeric kind, a fractional float, or a non-finite one. The integral-float
  // rule is `Predicate.cmpFloatInt`'s, so a probe the heap index answers from an
  // integer key is answered from that same key here.
  func exactInt(v : Value) : ?Int = switch v {
    case (#nat n)   ?n;
    case (#int i)   ?i;
    case (#float f) if (Float.isNaN(f - f)) null            // NaN or ±inf
                    else if (f == Float.floor(f)) ?f.toInt() else null;
    case _          null;
  };

  // The cell a column of type `t` would have to hold for a row to equal the query
  // value `v`, or null when the column can hold no such cell. Same-kind values map
  // straight across; the numeric kinds bridge exactly as `Predicate.compare` does,
  // so a probe arriving as 3.0 or `#int 3` finds the `#nat 3` cells. A fractional
  // float, a negative against a #nat column, or a magnitude outside the 64-bit
  // cell range denotes no cell at all.
  func probeCell(t : Cell.ColType, v : Value) : ?Cell.Cell =
    switch (t, v) {
      case (#bool, #bool b) ?#bool b;
      case (#text, #text s) ?#text s;
      case (#nat, _) switch (exactInt v) {
        case (?i) if (i >= 0 and i <= 18_446_744_073_709_551_615) ?#nat(Nat64.fromNat(Int.abs i)) else null;
        case null null;
      };
      case (#int, _) switch (exactInt v) {
        case (?i) if (i >= -9_223_372_036_854_775_808 and i <= 9_223_372_036_854_775_807) ?#int(Int64.fromInt i) else null;
        case null null;
      };
      // A #hash base over a #float column is refused at commit (a float has no key
      // word), so no #float column is ever ready to probe.
      case _ null;
    };

  // How the region base of a column of type `t` should be probed for a query
  // value: the null run, a real key, or #absent.
  //
  // The base is keyed by RAW CELL BITS, and `HashSegment.cellBits` maps `#bool
  // true` and `#nat 1` onto the same key — so a key is derived ONLY through
  // `probeCell`, from a value the column could actually hold. Probing across kinds
  // would alias one kind's rows onto another's, and the executor's residual cannot
  // drop the copies: they satisfy the predicate. #absent means no loaded row can
  // hold the value, so the base contributes nothing.
  func regionProbe(t : Cell.ColType, v : Value) : { #nullRun; #key : HashSegment.Key; #absent } =
    switch v {
      case (#null_) #nullRun;
      case _ switch (HashSegment.keyOf(probeCell(t, v))) { case (?k) #key k; case null #absent };
    };

  func boundCell(v : ?Value) : ?Cell.Cell = switch v { case (?x) valueToBound(x); case null null };

  // Positions in `[from, to)` whose `ci` cell equals `v`, read from the store. This is
  // the TAIL an index base does not cover yet — rows loaded or appended since its last
  // segment committed. The base tiles `[0, coveredEnd)` and this starts there, so the
  // two are disjoint and their union needs no dedup.
  //
  // O(tail), not O(table): that is the whole point. A column mid-upload used to serve
  // from neither half, which made every query on it a full scan and, past a few hundred
  // thousand rows, no query at all.
  //
  // Matching goes through `Predicate.compare` on the cell VALUE rather than through the
  // index's key encoding, because this side is a scan: it must agree with what the
  // planner's own scan would have returned, including how a null cell compares. A
  // deleted row reads back as no row and is skipped.
  func tailMatches(self : Table, ci : Nat, from : Nat, to : Nat, pred : Value -> Bool) : Iter.Iter<Nat> {
    var pos = from;
    {
      next = func() : ?Nat {
        loop {
          if (pos >= to) return null;
          let here = pos;
          pos += 1;
          switch (self.store.getRow(here)) {
            case (?row) { if (pred(cellToValue(row[ci]))) return ?here };
            case null {};
          };
        };
      };
    };
  };

  // Positions for `col = v`: the region base over the prefix it covers (skipping DEAD),
  // then a scan of the tail it does not. Empty when `col` has no region base at all.
  // Unioned with the heap delta by the caller — which is empty in exactly the states
  // where the tail is not: a column only holds delta postings once it is ready, and
  // `reopenIndex` refuses to leave one behind.
  func basePoint(self : Table, col : Text, v : Value) : Iter.Iter<Nat> =
    switch (colIndexOf(self.names, col)) {
      case null Iter.empty<Nat>();
      case (?ci) switch (RegionIndex.servingEntry(self.rix, ci)) {
        case null Iter.empty<Nat>();
        case (?e) {
          let covered = switch (regionProbe(self.store.cols[ci], v)) {
            case (#nullRun) RegionIndex.point(self.rix, e, null);
            case (#key k)   RegionIndex.point(self.rix, e, ?k);
            case (#absent)  Iter.empty<Nat>();
          };
          let end = appended(self);
          covered.concat(tailMatches(self, ci, RegionIndex.tailStart(e, end), end,
            func (x : Value) : Bool = Predicate.compare(x, v) == #equal));
        };
      };
    };

  // Base positions for `col in keys` — the union over de-duplicated keys.
  func basePoints(self : Table, col : Text, keys : [Value]) : Iter.Iter<Nat> =
    switch (colIndexOf(self.names, col)) {
      case null Iter.empty<Nat>();
      case (?ci) switch (RegionIndex.servingEntry(self.rix, ci)) {
        case null Iter.empty<Nat>();
        case (?e) {
          let seen = Set.empty<Value>();
          let uniq = List.empty<Value>();
          for (k in keys.values()) { if (not seen.contains(Predicate.compare, k)) { seen.add(Predicate.compare, k); uniq.add(k) } };
          let covered = uniq.values().flatMap<Value, Nat>(func (k : Value) : Iter.Iter<Nat> =
            switch (regionProbe(self.store.cols[ci], k)) {
              case (#nullRun) RegionIndex.point(self.rix, e, null);
              case (#key kk)  RegionIndex.point(self.rix, e, ?kk);
              case (#absent)  Iter.empty<Nat>();
            });
          // ONE pass over the tail for the whole key set, not one per key: the keys are
          // already de-duplicated, and a row matches at most one of them, so a position
          // still cannot come back twice.
          let ks = uniq.toArray();
          let end = appended(self);
          covered.concat(tailMatches(self, ci, RegionIndex.tailStart(e, end), end,
            func (x : Value) : Bool {
              for (k in ks.values()) { if (Predicate.compare(x, k) == #equal) return true };
              false;
            }));
        };
      };
    };

  // Base + delta group histogram: fold both into one value→count map. O(distinct)
  // heap, unavoidable for a group-by whose output is already O(distinct).
  func mergedGroupCount(self : Table, e : RegionIndex.Entry, ci : Nat, col : Text) : Iter.Iter<(Value, Nat)> {
    let m = Map.empty<Value, Nat>();
    func acc(v : Value, n : Nat) = switch (m.get(Predicate.compare, v)) {
      case (?x) m.add(Predicate.compare, v, x + n);
      case null m.add(Predicate.compare, v, n);
    };
    for ((cellOpt, n) in RegionIndex.groupCounts(self.rix, e)) acc(cellToValue(cellOpt), n);
    // The tail the base does not cover, one row at a time. A group-by whose base is a
    // prefix would otherwise report every group short, and a group that exists ONLY in
    // the tail would be missing entirely.
    let end = appended(self);
    var pos = RegionIndex.tailStart(e, end);
    while (pos < end) {
      switch (self.store.getRow(pos)) { case (?row) acc(cellToValue(row[ci]), 1); case null {} };
      pos += 1;
    };
    switch (SecondaryIndex.groupCount(self.ix, col)) { case (?it) { for ((v, n) in it) acc(v, n) }; case null {} };
    m.entries();
  };

  // ── OQL entity ──────────────────────────────────────────────────────────

  /// An OQL entity over the table, defaulting the schema `typeName` to `name`
  /// and the primary-key field to `"id"` — the shape almost every table uses.
  /// Use `entityWith` to override either.
  public func entity(self : Table, name : Text) : Entity.Builder<(Nat, [?Cell.Cell])> =
    entityWith(self, name, name, "id");

  /// An OQL entity over the table with an explicit schema `typeName` and
  /// primary-key field name. The served row is the store position (under
  /// `primaryKey`) plus the stored columns; index postings resolve to rows by
  /// reading their cells from the Region. Sargable unrestricted queries are
  /// answered from the index; anything else falls back to the scan.
  public func entityWith(self : Table, name : Text, typeName : Text, primaryKey : Text) : Entity.Builder<(Nat, [?Cell.Cell])> {
    // The row-id is exposed under `primaryKey`; if a stored column shares that
    // name the served row would carry two fields with it and the id would
    // shadow the stored value — reject it up front.
    switch (colIndexOf(self.names, primaryKey)) {
      case (?_) Runtime.trap("Table.entityWith: primaryKey \"" # primaryKey # "\" collides with a stored column; use a name not in the table's columns");
      case null {};
    };
    let base = Entity.new<(Nat, [?Cell.Cell])>(
      name, func () = self.store.scan(), typeName, primaryKey,
      func ((pos, cells) : (Nat, [?Cell.Cell])) : Row = fullRow(self.names, self.store.cols, primaryKey, pos, cells));
    // Seed schema derivation from the DECLARED columns rather than from a stored
    // row. `Entity.build` otherwise takes the first row of the entity as its
    // seed, and a table is empty when a canister is first installed — so an
    // entity built during initialisation (which is what `include Expose(...)`
    // does) would report no fields at all, and with them no declared edges, for
    // the whole life of the installation. The column names and types are known
    // up front, so a synthetic row is both available and exact. `Entity.sample`
    // clears before it sets, so a caller's own `.sample` still overrides this.
    let seed = Array.tabulate<?Cell.Cell>(self.names.size(), func (i : Nat) : ?Cell.Cell =
      switch (self.store.cols[i]) {
        case (#nat)   ?#nat(0);
        case (#int)   ?#int(0);
        case (#float) ?#float(0.0);
        case (#bool)  ?#bool(false);
        case (#text)  ?#text("");
        case (#bytes _) null;   // skipped by fullRow — never a schema field
      });
    let sampled = base.sample<(Nat, [?Cell.Cell])>((0, seed));
    sampled.withServed<(Nat, [?Cell.Cell])>(func (_toPredRow : ((Nat, [?Cell.Cell])) -> Predicate.Row) : Entity.Served {
      // Resolve a column name to its store index. Hoisted out of `lazyRow` so
      // the closure is shared across every served row (not rebuilt per row),
      // and written as an early-exiting index loop: it stops at the match and
      // allocates no iterator, unlike a `for … in names.values()` scan. `get`
      // is called once per touched cell per row, so this is the hot path — the
      // previous version allocated an iterator and walked all columns on every
      // single cell read, which is what made a wide full-row scan cost more
      // than a flat read. Column counts are small, so a linear probe beats a
      // hash map.
      func idxOf(colName : Text) : ?Nat {
        var i = 0;
        let n = self.names.size();
        while (i < n) { if (self.names[i] == colName) return ?i; i += 1 };
        null;
      };
      // Lazy projection: an index-served row reads only the columns the query
      // touches. `reader` resolves the row's segment once; `get` then pulls a
      // single cell on demand. `slot = null` routes the executor through `get`
      // (it never pre-materialises the full row). The primary key is the
      // position; other paths resolve a column by name.
      func lazyRow(pos : Nat, rd : Nat -> ?Cell.Cell) : Predicate.Row = {
        get = func (path : [Text]) : ?Value {
          if (path.size() != 1) return null;
          let colName = path[0];
          if (colName == primaryKey) return ?#nat(pos);
          switch (idxOf(colName)) {
            case (?idx) {
              // A #bytes column is absent from the served row too, matching fullRow.
              if (Cell.bytesWidth(self.store.cols[idx]) != null) return null;
              ?cellToValue(rd(idx));
            };
            case null null;
          };
        };
        slot = null;
        values = [];
      };
      func rows(refs : Iter.Iter<Nat>) : Iter.Iter<Predicate.Row> =
        refs.filterMap(func (pos : Nat) : ?Predicate.Row =
          self.store.reader(pos).map<(Nat -> ?Cell.Cell), Predicate.Row>(func (rd) = lazyRow(pos, rd)));
      {
        // `kindOf`/`point`/`points` merge the region base with the heap delta;
        // for a table with no region index every branch collapses to the heap
        // path, byte-for-byte the prior behaviour. `point`/`points` union base
        // and delta positions (disjoint: base < base.rows, delta at/after it).
        kindOf = func (col : Text) : ?SecondaryIndex.Kind =
          switch (colIndexOf(self.names, col)) {
            case (?ci) switch (RegionIndex.kindOf(self.rix, ci)) { case (?k) ?k; case null SecondaryIndex.kindOf(self.ix, col) };
            case null SecondaryIndex.kindOf(self.ix, col);
          };
        point  = func (col : Text, key : Value) : Iter.Iter<Predicate.Row> =
          rows((basePoint(self, col, key)).concat(SecondaryIndex.point(self.ix, col, key)));
        points = func (col : Text, keys : [Value]) : Iter.Iter<Predicate.Row> =
          rows((basePoints(self, col, keys)).concat(SecondaryIndex.points(self.ix, col, keys)));
        // A `#hash` base carries no order, so a range on a region-indexed column
        // is served by the whole-store zone-map scan (a correct superset over base
        // AND delta), not the delta-only heap range. Non-region columns keep the
        // heap range unchanged. The executor only reaches this for a #hash column
        // via a range predicate; #ordered range/orderBy is a later deliverable.
        range  = func (col : Text, lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : Iter.Iter<Predicate.Row> =
          switch (colIndexOf(self.names, col)) {
            // `servingEntry`, not `readyEntry`: a column mid-upload now advertises its
            // kind, so the executor can reach this for one whose base is a prefix. The
            // heap branch below would answer it from a delta that does not exist —
            // empty, silently. The store pass covers base, tail and delta alike.
            case (?ci) switch (RegionIndex.servingEntry(self.rix, ci)) {
              case (?_) rows(self.store.positionsWhere(ci, boundCell(lo), boundCell(hi)));
              case null rows(SecondaryIndex.range(self.ix, col, lo, hi, dir));
            };
            case null rows(SecondaryIndex.range(self.ix, col, lo, hi, dir));
          };
        composites = ?{
          decls = func () : [[Text]] = SecondaryIndex.readyComposites(self.ix);
          range = func (cols : [Text], prefixEqs : [Value], lo : ?Value, hi : ?Value, dir : { #asc; #desc }) : Iter.Iter<Predicate.Row> =
            rows(SecondaryIndex.compositeRange(self.ix, cols, prefixEqs, lo, hi, dir));
        };
        // Zone-map-pruned scan fall-back: skip whole segments whose footer
        // min/max exclude a single-column range/eq constraint, then read the
        // survivors lazily. A superset — the executor re-applies the predicate.
        prune = ?(func (where_ : ?Predicate.Predicate) : Iter.Iter<Predicate.Row> {
          let (c, lo, hi) = rangeConstraint(self.names, where_);
          rows(switch c {
            case (?ci) self.store.positionsWhere(ci, lo, hi);
            case null self.store.positionsWhere(0, null, null);
          });
        });
        stats = ?{
          total      = func () : Nat = self.store.count();
          // count/groupCount ADD the base to the delta. min/max take a different
          // route: only a column with an `#ordered` HEAP index is answered from
          // that index; every other non-#text column — a `#hash` region column
          // included — is answered from the store, whose per-segment footers cover
          // base and delta alike. `extremesExact` gates on the column's cell type
          // alone, not on any index.
          count      = func (col : Text, v : Value) : ?Nat {
            let d = SecondaryIndex.count(self.ix, col, v);
            switch (colIndexOf(self.names, col)) {
              case (?ci) switch (RegionIndex.servingEntry(self.rix, ci)) {
                case (?e) {
                  let b = switch (regionProbe(self.store.cols[ci], v)) {
                    case (#nullRun) RegionIndex.count(self.rix, e, null);
                    case (#key k)   RegionIndex.count(self.rix, e, ?k);
                    case (#absent)  0;
                  };
                  // The base counts its prefix; the tail is counted by walking it. Both
                  // must be here or the answer is short by exactly the rows loaded since
                  // the last commit — a wrong number, not a slow one.
                  var t = 0;
                  let end = appended(self);
                  for (_ in tailMatches(self, ci, RegionIndex.tailStart(e, end), end,
                         func (x : Value) : Bool = Predicate.compare(x, v) == #equal)) t += 1;
                  switch d { case (?dd) ?(b + t + dd); case null ?(b + t) };
                };
                case null d;
              };
              case null d;
            };
          };
          // Planner-only count: heap postings and the covered region base are
          // cheap exact metadata. Only an uncovered store tail is row-scanned,
          // and that scan stops once its proven lower bound exceeds `limit`.
          countUpTo = func (col : Text, v : Value, limit : Nat) : ?Entity.CountEstimate {
            let d = SecondaryIndex.count(self.ix, col, v);
            switch (colIndexOf(self.names, col)) {
              case (?ci) switch (RegionIndex.servingEntry(self.rix, ci)) {
                case (?e) {
                  var total = d ?? 0;
                  let base = switch (regionProbe(self.store.cols[ci], v)) {
                    case (#nullRun) RegionIndex.count(self.rix, e, null);
                    case (#key k)   RegionIndex.count(self.rix, e, ?k);
                    case (#absent)  0;
                  };
                  total += base;
                  let end = appended(self);
                  let tailStart = RegionIndex.tailStart(e, end);
                  if (tailStart == end) return ?#exact(total);
                  if (total > limit) return ?#atLeast(total);
                  for (_ in tailMatches(self, ci, tailStart, end,
                         func (x : Value) : Bool = Predicate.compare(x, v) == #equal)) {
                    total += 1;
                    if (total > limit) return ?#atLeast(total);
                  };
                  ?#exact(total)
                };
                case null d.map<Nat, Entity.CountEstimate>(func n = #exact(n));
              };
              case null d.map<Nat, Entity.CountEstimate>(func n = #exact(n));
            };
          };
          // An `#ordered` heap index is kept in VALUE order, so its end is the
          // extreme in one lookup — cheaper than any store pass, and the path that
          // already served these. Otherwise take it from the store: every row, base
          // and post-commit delta alike, is there, and the per-segment footers make
          // it O(segments). Exact under deletes either way (see `Columnar.minOf`).
          // `null` means no live non-null cell, which the executor renders `#null_`.
          min        = func (col : Text) : ?Value =
            if (SecondaryIndex.kindOf(self.ix, col) == ?#ordered) SecondaryIndex.minOf(self.ix, col)
            else switch (colIndexOf(self.names, col)) {
              case (?ci) switch (self.store.minOf(ci)) { case (?c) ?cellToValue(?c); case null null };
              case null null;
            };
          max        = func (col : Text) : ?Value =
            if (SecondaryIndex.kindOf(self.ix, col) == ?#ordered) SecondaryIndex.maxOf(self.ix, col)
            else switch (colIndexOf(self.names, col)) {
              case (?ci) switch (self.store.maxOf(ci)) { case (?c) ?cellToValue(?c); case null null };
              case null null;
            };
          groupCount = func (col : Text) : ?Iter.Iter<(Value, Nat)> =
            switch (colIndexOf(self.names, col)) {
              case (?ci) switch (RegionIndex.servingEntry(self.rix, ci)) {
                case (?e) ?mergedGroupCount(self, e, ci, col);
                case null SecondaryIndex.groupCount(self.ix, col);
              };
              case null SecondaryIndex.groupCount(self.ix, col);
            };
          sum        = func (col : Text) : ?Value = colSum(self, col);
          avg        = func (col : Text) : ?Value = colAvg(self, col);
          // #text carries no zone map, so a store pass over it IS a scan: do not
          // advertise it as servable, and let the planner scan as it did before.
          // #text carries no zone map, so a store pass over it IS a scan — nothing to
          // advertise. Every other column answers from footers, floats included: `Cell.lt`
          // is a total order over floats, so a NaN cannot hide from an extreme.
          extremesExact = func (col : Text) : Bool =
            switch (colIndexOf(self.names, col)) {
              case (?ci) switch (self.store.cols[ci]) { case (#text) false; case (#bytes _) false; case _ true };
              case null false;
            };
        };
      }
    });
  };

};
