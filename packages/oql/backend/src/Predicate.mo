/// Predicate AST + evaluator. Ten relational/logical variants plus four
/// text-search variants; remaining convenience predicates (`#between`,
/// `#isNull`, ...) compose from these.

import Array "mo:core/Array";
import Bool  "mo:core/Bool";
import Float "mo:core/Float";
import Int   "mo:core/Int";
import Iter  "mo:core/Iter";
import Nat   "mo:core/Nat";
import Order "mo:core/Order";
import Text  "mo:core/Text";
import Types "Types";

module {

  type Value = Types.Value;
  type Path  = Types.Path;

  public type Predicate = {
    #eq  : (Path, Value);
    #ne  : (Path, Value);
    #lt  : (Path, Value);
    #le  : (Path, Value);
    #gt  : (Path, Value);
    #ge  : (Path, Value);
    #in_ : (Path, [Value]);
    // Text-search relations: true only when both the row value and the
    // operand are `#text`. `#icontains` is case-insensitive (Unicode
    // lowercasing on both sides).
    #contains   : (Path, Value);
    #icontains  : (Path, Value);
    #startsWith : (Path, Value);
    #endsWith   : (Path, Value);
    #and_ : [Predicate];
    #or_  : [Predicate];
    #not_ : Predicate;
  };

  /// A row, viewed for predicate evaluation: it knows how to resolve a path
  /// to a value (or to `null` if the path is absent / hidden).
  ///
  /// Flat-layout fast path for base rows. `slot` resolves a top-level column
  /// name to an index into `values` ONCE (the resolver is shared across every
  /// row of the entity, so no per-row allocation), and `values` is this row's
  /// flat cells — so the executor can resolve a query's columns once and then
  /// index `values` directly per row instead of a name lookup per access.
  /// `slot` is `null` for rows without a flat layout (seed-less / aggregated),
  /// where callers fall back to `get` (and `values` is unused, `[]`).
  public type Row = {
    get    : Path -> ?Value;
    slot   : ?(Text -> ?Nat);
    values : [Value];
  };

  /// Total Boolean semantics — no three-valued logic. A stored `#null_` fails
  /// every ordered relation (see `ordered`), `eq`/`ne` against `#null_` are the
  /// explicit is-null / is-not-null tests, and `ne` against a value matches
  /// null rows (every `ne` is the exact complement of its `eq`). A MISSING
  /// field fails every relation except `#ne`, which is true for any operand.
  /// The statement of record, with the deliberate differences from SQL, is the
  /// "Null semantics" section of the README.
  public func eval(p : Predicate, row : Row) : Bool {
    switch p {
      case (#eq  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #equal) };
      case (#ne  (path, v)) { test(row.get(path), true,  func a = compare(a, v) != #equal) };
      case (#lt  (path, v)) { ordered(row.get(path), v, func o = o == #less) };
      case (#le  (path, v)) { ordered(row.get(path), v, func o = o != #greater) };
      case (#gt  (path, v)) { ordered(row.get(path), v, func o = o == #greater) };
      case (#ge  (path, v)) { ordered(row.get(path), v, func o = o != #less) };
      case (#in_ (path, vs)) {
        test(row.get(path), false, func a = vs.values().any(func v = compare(a, v) == #equal))
      };
      case (#contains   (path, v)) { textTest(row.get(path), v, func (h, n) = h.contains(#text n)) };
      case (#icontains  (path, v)) { textTest(row.get(path), v, func (h, n) = h.toLower().contains(#text(n.toLower()))) };
      case (#startsWith (path, v)) { textTest(row.get(path), v, func (h, n) = h.startsWith(#text n)) };
      case (#endsWith   (path, v)) { textTest(row.get(path), v, func (h, n) = h.endsWith(#text n)) };
      case (#and_ ps) { ps.values().all(func q = eval(q, row)) };
      case (#or_  ps) { ps.values().any(func q = eval(q, row)) };
      case (#not_ q)  { not eval(q, row) };
    }
  };

  /// `eval(p, _)` compiled once: leaves are specialised to their operand and
  /// read flat rows by slot instead of by name. Answers exactly as `eval` does.
  /// Use one compiled predicate per row stream: slots are resolved from the
  /// first flat row and reused, per the `Row` contract that an entity's flat
  /// rows share one resolver.
  public func compile(p : Predicate) : Row -> Bool =
    switch p {
      case (#eq (path, v)) {
        let rd = reader(path);
        let ok = eqTo(v);
        func r = switch (rd(r)) { case (?a) ok(a); case null false };
      };
      case (#ne (path, v)) {
        let rd = reader(path);
        let ok = eqTo(v);
        func r = switch (rd(r)) { case (?a) not ok(a); case null true };
      };
      case (#lt (path, v)) { orderedLeaf(path, v, true, false, false) };
      case (#le (path, v)) { orderedLeaf(path, v, true, true, false) };
      case (#gt (path, v)) { orderedLeaf(path, v, false, false, true) };
      case (#ge (path, v)) { orderedLeaf(path, v, false, true, true) };
      case (#in_ (path, vs)) {
        let rd = reader(path);
        let oks = vs.map<Value, Value -> Bool>(eqTo);
        func r = switch (rd(r)) {
          case (?a) { for (ok in oks.vals()) { if (ok(a)) return true }; false };
          case null false;
        };
      };
      case (#contains (path, v)) {
        textLeaf(path, v, func n { let pat = #text n; func h = h.contains(pat) })
      };
      case (#icontains (path, v)) {
        textLeaf(path, v, func n { let pat = #text(n.toLower()); func h = h.toLower().contains(pat) })
      };
      case (#startsWith (path, v)) {
        textLeaf(path, v, func n { let pat = #text n; func h = h.startsWith(pat) })
      };
      case (#endsWith (path, v)) {
        textLeaf(path, v, func n { let pat = #text n; func h = h.endsWith(pat) })
      };
      case (#and_ ps) {
        let cs = ps.map<Predicate, Row -> Bool>(compile);
        func r { for (c in cs.vals()) { if (not c(r)) return false }; true };
      };
      case (#or_ ps) {
        let cs = ps.map<Predicate, Row -> Bool>(compile);
        func r { for (c in cs.vals()) { if (c(r)) return true }; false };
      };
      case (#not_ q) { let c = compile(q); func r = not c(r) };
    };

  func reader(path : Path) : Row -> ?Value {
    if (path.size() != 1) return func r = r.get(path);
    let name = path[0];
    var resolved = false;
    var at : ?Nat = null;
    func r = switch (r.slot) {
      case null r.get(path);
      case (?resolve) {
        if (not resolved) { at := resolve(name); resolved := true };
        // An unresolved name (absent or masked) still goes through `get`.
        switch at { case (?i) ?r.values[i]; case null r.get(path) };
      };
    };
  };

  // `compare(_, v) == #equal`, specialised to the operand.
  func eqTo(v : Value) : Value -> Bool =
    switch v {
      case (#null_)  func a = switch a { case (#null_) true; case _ false };
      case (#bool b) func a = switch a { case (#bool x) x == b; case _ false };
      case (#text t) func a = switch a { case (#text x) x == t; case _ false };
      case (#nat n)  eqToInt(n, v);
      case (#int n)  eqToInt(n, v);
      case (#float y) {
        let cmp = cmpToFloat(y, v);
        func a = switch a { case (#nat _ or #int _ or #float _) cmp(a) == #equal; case _ false };
      };
    };

  func eqToInt(n : Int, v : Value) : Value -> Bool {
    let cmp = cmpToInt(n, v);
    func a = switch a {
      case (#nat x) x == n;
      case (#int x) x == n;
      case (#float _) cmp(a) == #equal;
      case _ false;
    };
  };

  // `compare(_, v)`, specialised to the operand.
  func cmpTo(v : Value) : Value -> Order.Order =
    switch v {
      case (#nat n)   cmpToInt(n, v);
      case (#int n)   cmpToInt(n, v);
      case (#float y) cmpToFloat(y, v);
      case (#text t)  func a = switch a { case (#text x) x.compare(t); case _ compare(a, v) };
      case _          func a = compare(a, v);
    };

  // Integers up to 2^53 convert to Float exactly, so a float row can compare
  // against such an operand as a float; past it only `cmpFloatInt` is exact.
  let EXACT_INT : Nat = 9_007_199_254_740_992;

  func cmpToInt(n : Int, v : Value) : Value -> Order.Order {
    if (Int.abs(n) > EXACT_INT) {
      return func a = switch a {
        case (#nat x) Int.compare(x, n);
        case (#int x) Int.compare(x, n);
        case _ compare(a, v);
      };
    };
    let f = n.toFloat();
    func a = switch a {
      case (#nat x) Int.compare(x, n);
      case (#int x) Int.compare(x, n);
      case (#float x) Float.compare(x, f);
      case _ compare(a, v);
    };
  };

  // `compare(_, #float y)`; the integer cases are `cmpFloatInt` with `y`'s floor taken once.
  func cmpToFloat(y : Float, v : Value) : Value -> Order.Order {
    if (Float.isNaN(y - y)) {
      return func a = switch a { case (#float x) Float.compare(x, y); case _ compare(a, v) };
    };
    let fl = Float.floor(y);
    let fi = fl.toInt();
    if (y == fl) {
      func a = switch a {
        case (#float x) Float.compare(x, y);
        case (#nat x) Int.compare(x, fi);
        case (#int x) Int.compare(x, fi);
        case _ compare(a, v);
      };
    } else {
      func a = switch a {
        case (#float x) Float.compare(x, y);
        case (#nat x) if (x <= fi) #less else #greater;
        case (#int x) if (x <= fi) #less else #greater;
        case _ compare(a, v);
      };
    };
  };

  // Compiled `ordered`: the flags say which orders satisfy the relation.
  func orderedLeaf(path : Path, v : Value, onLess : Bool, onEqual : Bool, onGreater : Bool) : Row -> Bool {
    let rd = reader(path);
    switch v {
      // Still reads the row, so a trapping traversal traps as it does in `eval`.
      case (#null_) { func r { ignore rd(r); false } };
      case _ {
        let cmp = cmpTo(v);
        func r = switch (rd(r)) {
          case (null or ?#null_) false;
          case (?a) switch (cmp(a)) { case (#less) onLess; case (#equal) onEqual; case (#greater) onGreater };
        };
      };
    };
  };

  // Compiled `textTest`; `rel` receives the needle once and returns the per-row test.
  func textLeaf(path : Path, v : Value, rel : Text -> (Text -> Bool)) : Row -> Bool {
    let rd = reader(path);
    switch v {
      case (#text n) { let ok = rel(n); func r = switch (rd(r)) { case (?#text h) ok(h); case _ false } };
      case _ { func r { ignore rd(r); false } }; // reads, as in `orderedLeaf`
    };
  };

  /// True when `actual` is present and `ok` accepts it; `onNull` is the
  /// answer when the field is missing. `eval`'s null policy lives here;
  /// `compile`'s leaves mirror it, so a policy change must edit both.
  func test(actual : ?Value, onNull : Bool, ok : Value -> Bool) : Bool =
    switch actual { case null { onNull }; case (?a) { ok(a) } };

  /// An ordered relation (`lt`/`le`/`gt`/`ge`), null-hostile on BOTH sides: a
  /// row whose value is `#null_` matches no range, and a `#null_` operand
  /// bounds nothing. This cannot be `test` over a raw `compare`: `compare`'s
  /// total order ranks kinds (`null < bool < number < text`) so SORTS stay
  /// total, and under that order a raw comparison happily calls a null "less
  /// than 0" — admitting every null row into `col < 0`, an answer no reader
  /// expects and one the columnar zone map (whose min/max exclude nulls) would
  /// contradict by pruning. The kind rank gives null a position in a sort, not
  /// on the number line. An explicit null test remains `#eq`/`#ne` against a
  /// `#null_` operand.
  func ordered(actual : ?Value, v : Value, ok : Order.Order -> Bool) : Bool =
    switch (actual, v) {
      case (?#null_, _) { false };
      case (_, #null_) { false };
      case (?a, _) { ok(compare(a, v)) };
      case (null, _) { false };
    };

  /// Text-only relation: true only when both the row value (haystack) and
  /// the operand (needle) are `#text` and `rel` accepts them. Missing or
  /// non-text fields are false, consistent with the null policy above.
  func textTest(actual : ?Value, operand : Value, rel : (Text, Text) -> Bool) : Bool =
    switch (actual, operand) {
      case (?#text h, #text n) { rel(h, n) };
      case _ { false };
    };

  /// A genuine total order on `Value` — antisymmetric and transitive over
  /// every pair, which `orderBy`/`min`/`max` rely on (an inconsistent
  /// comparator silently corrupts sorts).
  ///
  /// `Nat`/`Int`/`Float` bridge each other: numeric values compare across
  /// these three regardless of which wire form they arrived in, so
  /// `gt(price, 10)` matches a row whose `price` is the Float 12.5.
  ///
  /// Cross-*kind* pairs (`#nat` vs `#text`, or anything vs `#null_`) order
  /// by a fixed kind rank — `null < bool < number < text` — so the answer
  /// is deterministic and self-consistent. (Meaningful queries still
  /// compare like with like; this just guarantees a stable sort when a
  /// column mixes kinds, e.g. a left-joined edge path yielding `null`.)
  ///
  /// Numeric pairs go through `Nat.compare`/`Int.compare`/`Float.compare`
  /// (mo:core names those parameters `x`/`y`, not `self`, so contextual dot
  /// is unavailable). `Float.compare` is itself already a total order across
  /// the float edge cases — NaN sorts greatest and equals only itself,
  /// `-0.0` equals `+0.0` — so no NaN special-casing is needed here. (Both
  /// properties are pinned by the test suite.)
  ///
  /// The `Float`↔`Int`/`Nat` bridge is EXACT (`cmpFloatInt`), not
  /// `Float.fromInt`: past 2^53 that conversion is lossy and would make one
  /// float `#equal` to two distinct integer keys, breaking transitivity — and
  /// with it any ordered structure keyed on `compare`, so an index probe would
  /// under-fetch. So `#eq(#float 2^53)` matches the integer `2^53` only, never
  /// also `2^53 + 1`. Below 2^53 the two bridges agree exactly.
  public func compare(a : Value, b : Value) : Order.Order =
    switch (a, b) {
      case (#null_,  #null_ ) { #equal };
      case (#bool x, #bool y) { x.compare(y) };
      case (#nat   x, #nat   y) { Nat.compare(x, y) };
      case (#int   x, #int   y) { Int.compare(x, y) };
      case (#nat   x, #int   y) { Int.compare(x, y) };
      case (#int   x, #nat   y) { Int.compare(x, y) };
      case (#float x, #float y) { Float.compare(x, y) };
      case (#float x, #nat   y) { cmpFloatInt(x, y) };
      case (#nat   x, #float y) { flipOrder(cmpFloatInt(y, x)) };
      case (#float x, #int   y) { cmpFloatInt(x, y) };
      case (#int   x, #float y) { flipOrder(cmpFloatInt(y, x)) };
      case (#text x, #text y) { x.compare(y) };
      // Different kinds: order by kind rank. (Same-kind pairs — including
      // every numeric combination — are all handled above, so this only
      // ever sees distinct ranks and is therefore strictly ±.)
      case _ { Nat.compare(rank(a), rank(b)) };
    };

  /// Compare a `Float` against an integer EXACTLY, so the numeric bridge stays a
  /// valid total order past 2^53. `Float.fromInt` is lossy there — `fromInt(2^53)
  /// == fromInt(2^53 + 1)` — which would make one float `#equal` to two distinct
  /// integer keys, breaking transitivity and with it every ordered `Map`/`Set`
  /// keyed on `compare` (a secondary-index point probe would land on one bucket
  /// and silently drop the other). An integral float compares as an integer; a
  /// non-integral float falls strictly between its integer neighbours. Non-finite
  /// floats (NaN/±inf) can't collide with an integer, so they keep the plain
  /// `Float.compare` bridge (already total over those).
  func cmpFloatInt(f : Float, i : Int) : Order.Order {
    if (Float.isNaN(f - f)) { return Float.compare(f, Float.fromInt(i)) }; // NaN or ±inf
    let fl = Float.floor(f);
    if (f == fl) { Int.compare(f.toInt(), i) }        // integral float → integer compare
    else if (i <= fl.toInt()) { #greater }            // f ∈ (floor, floor+1): f > i
    else { #less };                                        // i ≥ ceil: f < i
  };

  func flipOrder(o : Order.Order) : Order.Order =
    switch o { case (#less) { #greater }; case (#equal) { #equal }; case (#greater) { #less } };

  /// Fixed kind ordering for cross-kind comparisons. Numbers share a rank
  /// so the bridge cases above stay authoritative for numeric pairs.
  func rank(v : Value) : Nat = switch v {
    case (#null_) { 0 };
    case (#bool _) { 1 };
    case (#nat _ or #int _ or #float _) { 2 };
    case (#text _) { 3 };
  };

};
