/// The storage layer's cell vocabulary and the per-type encode / decode /
/// comparison / running-sum helpers.
///
/// The four numeric kinds are FIXED-WIDTH — one 8-byte word in a Region, so
/// `store`/`load` handle them here. `#text` is VARIABLE-WIDTH: it is stored
/// out-of-line by the column store (an offsets array + a packed byte buffer),
/// so `store`/`load` never touch it — they trap if asked. `isVar` distinguishes
/// the two. A consuming query layer maps its own scalar value type onto these.
import Region "mo:core/Region";
import Int64 "mo:core/Int64";
import Nat64 "mo:core/Nat64";
import Runtime "mo:core/Runtime";

import Float "mo:core/Float";

module {

  /// The type of a column — fixes how its cell is interpreted/stored.
  /// `#bytes w` is a fixed-width raw-byte column (all cells exactly `w` bytes,
  /// stored in-line at stride `w`); it is opaque to the query layer — no zone
  /// map, no sum, no order — and is read through its own accessor.
  public type ColType = { #nat; #int; #float; #bool; #text; #bytes : Nat };

  /// A decoded cell value (a column is homogeneous, so a cell's kind always
  /// matches its column's `ColType`). Absence (null) is tracked separately by a
  /// validity bitmap, so it is not a cell kind here.
  public type Cell = {
    #nat : Nat64;
    #int : Int64;
    #float : Float;
    #bool : Bool;
    #text : Text;
    #bytes : Blob;
  };

  /// Whether a column is variable-width (stored out-of-line, not as one word).
  public func isVar(t : ColType) : Bool = switch t { case (#text) true; case _ false };

  /// The stride of a `#bytes` column, null for every other type. Layout code
  /// branches on this BEFORE the fixed/var split, so the one-word fixed path
  /// stays untouched.
  public func bytesWidth(t : ColType) : ?Nat = switch t { case (#bytes w) ?w; case _ null };

  /// A running numeric total. Integer-kinded columns accumulate exactly as `Int`
  /// (a `Bool` column sums its true count); float columns accumulate as `Float`.
  public type Sum = { #int : Int; #float : Float };

  /// Write a fixed-width cell to `region` at byte offset `off`. `#text` is
  /// variable-width and stored out-of-line by the column store, never here.
  public func store(region : Region.Region, off : Nat64, cell : Cell) {
    switch cell {
      case (#nat n) region.storeNat64(off, n);
      case (#int i) region.storeNat64(off, i.toNat64()); // bit-reinterpret
      case (#float f) region.storeFloat(off, f);
      case (#bool b) region.storeNat64(off, if b 1 else 0);
      case (#text _) Runtime.trap("Cell.store: #text is variable-width, stored out-of-line");
      case (#bytes _) Runtime.trap("Cell.store: #bytes is stored at its own stride, not as one word");
    };
  };

  /// Read a fixed-width cell of the given column type from `region` at byte
  /// offset `off`. `#text` is variable-width and read out-of-line, never here.
  public func load(region : Region.Region, off : Nat64, t : ColType) : Cell {
    switch t {
      case (#nat) #nat(region.loadNat64(off));
      case (#int) #int(Int64.fromNat64(region.loadNat64(off))); // bit-reinterpret
      case (#float) #float(region.loadFloat(off));
      case (#bool) #bool(region.loadNat64(off) == 1);
      case (#text) Runtime.trap("Cell.load: #text is variable-width, read out-of-line");
      case (#bytes _) Runtime.trap("Cell.load: #bytes is read at its own stride, not as one word");
    };
  };

  /// Strict less-than over two cells of the same kind (false < true for bools).
  public func lt(a : Cell, b : Cell) : Bool {
    switch (a, b) {
      case (#nat x, #nat y) x < y;
      case (#int x, #int y) x < y;
      // `Float.compare`, not `<`: `<` is false in both directions against NaN, which makes
      // this not a total order — a NaN then never becomes a footer extreme, and a zone map
      // built from that footer prunes away the very rows a `>` predicate matches. This order
      // is the one `Predicate.compare` uses, where NaN sorts greatest and equals itself.
      case (#float x, #float y) Float.compare(x, y) == #less;
      case (#bool x, #bool y) (not x) and y;
      case (#text x, #text y) x < y;
      case _ false;
    };
  };

  /// The zero total for a column of the given type.
  public func zeroSum(t : ColType) : Sum {
    switch t { case (#float) #float(0.0); case _ #int(0) };
  };

  /// Fold a cell into a running total.
  public func addSum(s : Sum, c : Cell) : Sum {
    switch (s, c) {
      case (#int acc, #nat n) #int(acc + n.toNat());
      case (#int acc, #int i) #int(acc + i.toInt());
      case (#int acc, #bool b) #int(acc + (if b 1 else 0));
      case (#float acc, #float f) #float(acc + f);
      case (unchanged, _) unchanged;
    };
  };

  /// Remove a cell from a running total (for logical deletes).
  public func subSum(s : Sum, c : Cell) : Sum {
    switch (s, c) {
      case (#int acc, #nat n) #int(acc - n.toNat());
      case (#int acc, #int i) #int(acc - i.toInt());
      case (#int acc, #bool b) #int(acc - (if b 1 else 0));
      case (#float acc, #float f) #float(acc - f);
      case (unchanged, _) unchanged;
    };
  };
};
