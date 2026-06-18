/// Predicate AST + evaluator. Ten relational/logical variants plus four
/// text-search variants; remaining convenience predicates (`#between`,
/// `#isNull`, ...) compose from these.

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
  public type Row = { get : Path -> ?Value };

  /// Missing fields fail every relation **except `#ne`** — strict
  /// three-valued logic is a later change.
  public func eval(p : Predicate, row : Row) : Bool {
    switch p {
      case (#eq  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #equal) };
      case (#ne  (path, v)) { test(row.get(path), true,  func a = compare(a, v) != #equal) };
      case (#lt  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #less) };
      case (#le  (path, v)) { test(row.get(path), false, func a = compare(a, v) != #greater) };
      case (#gt  (path, v)) { test(row.get(path), false, func a = compare(a, v) == #greater) };
      case (#ge  (path, v)) { test(row.get(path), false, func a = compare(a, v) != #less) };
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

  /// True when `actual` is present and `ok` accepts it; `onNull` is the
  /// answer when the field is missing. Centralises the null policy so
  /// strict 3VL is a single-flag change at every call site.
  func test(actual : ?Value, onNull : Bool, ok : Value -> Bool) : Bool =
    switch actual { case null { onNull }; case (?a) { ok(a) } };

  /// Text-only relation: true only when both the row value (haystack) and
  /// the operand (needle) are `#text` and `rel` accepts them. Missing or
  /// non-text fields are false, consistent with the null policy above.
  func textTest(actual : ?Value, operand : Value, rel : (Text, Text) -> Bool) : Bool =
    switch (actual, operand) {
      case (?#text h, #text n) { rel(h, n) };
      case _ { false };
    };

  /// Total ordering on `Value`. Type-mixed comparisons (`#nat` vs `#text`)
  /// are deterministic but meaningless — callers compare like with like.
  /// `Nat`/`Int`/`Float` bridge each other: numeric values compare
  /// across these three regardless of which wire form they arrived in,
  /// so `gt(price, 10)` matches a row whose `price` is the Float 12.5.
  /// `Nat`/`Int`/`Float` go through `Nat.compare`/`Int.compare`/
  /// `Float.compare` because mo:core names those parameters `x`/`y`,
  /// not `self`, so contextual dot is unavailable.
  public func compare(a : Value, b : Value) : Order.Order =
    switch (a, b) {
      case (#null_,  #null_ ) { #equal };
      case (#bool x, #bool y) { x.compare(y) };
      case (#nat   x, #nat   y) { Nat.compare(x, y) };
      case (#int   x, #int   y) { Int.compare(x, y) };
      case (#nat   x, #int   y) { Int.compare(x, y) };
      case (#int   x, #nat   y) { Int.compare(x, y) };
      case (#float x, #float y) { Float.compare(x, y) };
      case (#float x, #nat   y) { Float.compare(x, Float.fromInt(y)) };
      case (#nat   x, #float y) { Float.compare(Float.fromInt(x), y) };
      case (#float x, #int   y) { Float.compare(x, Float.fromInt(y)) };
      case (#int   x, #float y) { Float.compare(Float.fromInt(x), y) };
      case (#text x, #text y) { x.compare(y) };
      case _ { #less };
    };

};
