/// Differential test: `Predicate.compile(p)` answers exactly as
/// `Predicate.eval(p, _)` over every operator, operand kind and row value, on
/// flat, map-backed, hidden-masked and edge-path rows.

import {test} "mo:test";
import Array "mo:core/Array";
import Float "mo:core/Float";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Predicate "../src/Predicate";
import Types "../src/Types";

type Value = Types.Value;
type Path = Types.Path;
type Pred = Predicate.Predicate;
type Row = Predicate.Row;

let two53 : Nat = 9_007_199_254_740_992;
let inf : Float = 1.0 / 0.0;
let posNaN : Float = Float.copySign(0.0 / 0.0, 1.0);
let negNaN : Float = Float.copySign(0.0 / 0.0, -1.0);

// Every kind, numeric neighbours of 2^53 on all three numeric kinds, the
// integer floors of the fractional floats (1, -3, 4), signed zeros, both NaN
// signs, infinities, empty and non-ASCII text.
let VALUES : [Value] = [
  #null_,
  #bool false, #bool true,
  #nat 0, #nat 1, #nat 5, #nat two53, #nat(two53 + 1), #nat(2 ** 70), #nat(2 ** 1100),
  #int 0, #int(-1), #int 1, #int(-3), #int 4, #int 5, #int(-5), #int(two53 + 1), #int(-two53), #int(-(two53 + 1)), #int(-(2 ** 70)), #int(-(2 ** 1100)),
  #float 0.0, #float(-0.0), #float 1.5, #float(-2.5), #float 5.0, #float 4.999, #float(-5.0),
  #float 9_007_199_254_740_992.0, #float 9_007_199_254_740_994.0, #float(-9_007_199_254_740_992.0),
  #float 1_180_591_620_717_411_303_424.0, #float 1e300,
  #float inf, #float(-inf), #float posNaN, #float negNaN,
  #text "", #text "a", #text "abc", #text "ABC", #text "b", #text "bc",
  #text "ÜBER Straße", #text "über straße", #text "日本語", #text "本",
];

let IN_LISTS : [[Value]] = [
  [],
  [#null_],
  [#nat 5],
  [#int 5, #text "a"],
  [#float 5.0, #bool true],
  [#nat two53, #float 9_007_199_254_740_992.0],
  [#null_, #float posNaN, #float(-inf)],
  [#text "abc", #text "", #text "日本語"],
  VALUES,
];

func leaves(path : Path) : [Pred] {
  let acc = List.empty<Pred>();
  for (v in VALUES.vals()) {
    acc.add(#eq(path, v));
    acc.add(#ne(path, v));
    acc.add(#lt(path, v));
    acc.add(#le(path, v));
    acc.add(#gt(path, v));
    acc.add(#ge(path, v));
    acc.add(#contains(path, v));
    acc.add(#icontains(path, v));
    acc.add(#startsWith(path, v));
    acc.add(#endsWith(path, v));
  };
  for (vs in IN_LISTS.vals()) acc.add(#in_(path, vs));
  acc.toArray()
};

// Two-column shapes over `x` and `y`: and/or/not, nesting, and the empty forms.
func combos() : [Pred] {
  let xs : [Pred] = [
    #eq(["x"], #nat 5), #ne(["x"], #null_), #lt(["x"], #float 4.999), #ge(["x"], #int 0),
    #in_(["x"], [#text "abc", #float 5.0]), #icontains(["x"], #text "STRA"),
  ];
  let ys : [Pred] = [
    #eq(["y"], #null_), #gt(["y"], #text "a"), #le(["y"], #nat two53), #ne(["y"], #float posNaN),
    #startsWith(["y"], #text "ab"), #eq(["nope"], #null_),
  ];
  let acc = List.empty<Pred>();
  acc.add(#and_([]));
  acc.add(#or_([]));
  for (a in xs.vals()) {
    acc.add(#not_(a));
    acc.add(#not_(#not_(a)));
    for (b in ys.vals()) {
      acc.add(#and_([a, b]));
      acc.add(#or_([a, b]));
      acc.add(#and_([a, #or_([b, #not_(a)])]));
      acc.add(#or_([#and_([b, a]), #not_(#or_([a, b])), #and_([])]));
    };
  };
  acc.toArray()
};

// One layout per stream, as `Entity` builds seeded rows: a shared resolver
// over a fixed column order, per-row `values`.
func flatRows(names : [Text], cells : [[Value]]) : [Row] {
  let index = Map.empty<Text, Nat>();
  for (i in names.keys()) index.add(Text.compare, names[i], i);
  let slot = func (n : Text) : ?Nat = index.get(Text.compare, n);
  cells.map<[Value], Row>(func vs = {
    get = func (path : Path) : ?Value =
      if (path.size() != 1) null
      else switch (slot(path[0])) { case (?i) ?vs[i]; case null null };
    slot = ?slot;
    values = vs;
  })
};

// Map-backed rows (`slot = null`); a `null` cell leaves the column out.
func mapRows(names : [Text], cells : [[?Value]]) : [Row] =
  cells.map<[?Value], Row>(func vs {
    let m = Map.empty<Text, Value>();
    for (i in names.keys()) { switch (vs[i]) { case (?v) m.add(Text.compare, names[i], v); case null {} } };
    {
      get = func (path : Path) : ?Value = if (path.size() != 1) null else m.get(Text.compare, path[0]);
      slot = null;
      values = [];
    }
  });

// `Entity.maskRow`: the hidden cell stays in `values` but neither `get` nor
// `slot` may reach it.
func masked(r : Row, hidden : Text) : Row = {
  get = func (path : Path) : ?Value =
    if (path.size() > 0 and path[0] == hidden) null else r.get(path);
  slot = switch (r.slot) {
    case (?resolve) ?(func (n : Text) : ?Nat = if (n == hidden) null else resolve(n));
    case null null;
  };
  values = r.values;
};

// `Executor.wrapRow`: own columns first, an edge path `e.x` answered off a target.
func withEdge(r : Row, target : ?Value) : Row = {
  get = func (path : Path) : ?Value =
    switch (r.get(path)) {
      case (?v) ?v;
      case null if (path.size() == 2 and path[0] == "e" and path[1] == "x") target else null;
    };
  slot = r.slot;
  values = r.values;
};

// Compiles each predicate once and runs it over the whole stream, so the
// lazily resolved slots are reused exactly as the executor reuses them.
func check(what : Text, ps : [Pred], rows : [Row]) {
  var hits = 0;
  var misses = 0;
  for (p in ps.vals()) {
    let c = Predicate.compile(p);
    for (i in rows.keys()) {
      let want = Predicate.eval(p, rows[i]);
      if (c(rows[i]) != want) {
        Runtime.trap(what # ": row " # i.toText() # " " # debug_show (p) # " expected " # debug_show (want));
      };
      if (want) hits += 1 else misses += 1;
    };
  };
  // Guards against a degenerate matrix that would pass vacuously.
  assert hits > 0 and misses > 0;
};

let X_CELLS : [[Value]] = VALUES.map<Value, [Value]>(func v = [#nat 0, v, #text "y"]);

test("flat rows: every leaf, read by slot", func () {
  check("flat", leaves(["x"]), flatRows(["k", "x", "y"], X_CELLS));
});

test("flat rows: a column outside the layout reads as missing", func () {
  check("flat-missing", leaves(["nope"]), flatRows(["k", "x", "y"], X_CELLS));
});

test("map-backed rows: every leaf, including a missing column", func () {
  let cells = VALUES.map<Value, [?Value]>(func v = [?#nat 0, ?v]);
  let rows = mapRows(["k", "x"], cells);
  let missing = mapRows(["k", "x"], [[?#nat 0, null]]);
  check("map", leaves(["x"]), [missing[0]].concat(rows).concat(missing));
});

test("hidden columns read as absent through the mask", func () {
  let cells = VALUES.map<Value, [Value]>(func v = [#nat 0, v, v]);
  let rows = flatRows(["k", "h", "x"], cells).map<Row, Row>(func r = masked(r, "h"));
  check("masked-visible", leaves(["x"]), rows);
  check("masked-hidden", leaves(["h"]), rows);
  // Same answers as a row that never had the column.
  let absent = mapRows(["k"], [[?#nat 0]])[0];
  for (p in leaves(["h"]).vals()) {
    let c = Predicate.compile(p);
    for (r in rows.vals()) assert c(r) == Predicate.eval(p, absent);
  };
});

test("a name the slot resolver can't map is read through get", func () {
  let rows = VALUES.map<Value, Row>(func v = {
    get = func (path : Path) : ?Value = if (path.size() == 1 and path[0] == "x") ?v else null;
    slot = ?(func (_ : Text) : ?Nat = null);
    values = [];
  });
  check("unresolved", leaves(["x"]), rows);
});

test("edge paths always go through get", func () {
  let rows = flatRows(["k", "e"], [[#nat 0, #nat 1]]);
  let wrapped = VALUES.map<Value, Row>(func v = withEdge(rows[0], ?v));
  check("edge", leaves(["e", "x"]), wrapped.concat([withEdge(rows[0], null)]));
});

test("streams mixing flat and map-backed rows of one layout", func () {
  let flat = flatRows(["k", "x", "y"], X_CELLS);
  let map = mapRows(["k", "x", "y"], X_CELLS.map<[Value], [?Value]>(func vs = [?vs[0], ?vs[1], ?vs[2]]));
  check("map-first", leaves(["x"]), [map[3]].concat(flat));
  check("flat-first", leaves(["x"]), [flat[3]].concat(map));
});

test("and / or / not over two columns", func () {
  let sub : [Value] = [
    #null_, #bool true, #nat 5, #int(-1), #float 4.999, #float 5.0, #float posNaN,
    #nat two53, #text "abc", #text "a", #text "über straße",
  ];
  let cells = List.empty<[Value]>();
  for (x in sub.vals()) { for (y in sub.vals()) cells.add([x, y]) };
  let flat = flatRows(["x", "y"], cells.toArray());
  check("combo-flat", combos(), flat);
  // `#bool true` in `y` stands for a missing `y`.
  let maps = mapRows(["x", "y"], cells.toArray().map<[Value], [?Value]>(func vs =
    [?vs[0], switch (vs[1]) { case (#bool true) null; case v ?v }]));
  check("combo-map", combos(), maps);
});

test("reads and short-circuits exactly as eval", func () {
  // Counting `get` on map-backed rows pins evaluation order, short-circuiting,
  // and that fixed-answer leaves still read the row (a traversal that traps
  // must trap under both).
  var calls = 0;
  func counting(r : Row) : Row = {
    get = func (path : Path) : ?Value { calls += 1; r.get(path) };
    slot = null;
    values = [];
  };
  let rows = mapRows(["x", "y"], [[?#nat 5, ?#null_], [?#text "abc", null], [null, ?#float 1.5]])
    .map<Row, Row>(counting);
  for (p in combos().concat(leaves(["x"])).vals()) {
    let c = Predicate.compile(p);
    for (r in rows.vals()) {
      calls := 0;
      ignore Predicate.eval(p, r);
      let byEval = calls;
      calls := 0;
      ignore c(r);
      assert calls == byEval;
    };
  };
});
