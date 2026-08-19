/// Differential oracle for COMPOSITE (multi-column) ordered indexes, end to
/// end through the REAL executor. The same live rows sit behind two
/// registries — one index-served (composite declared), one plain scan — and
/// the scan is ground truth for the planner's SQL-semantics contract (as in
/// IndexedMapEntity.test.mo): every served row is a genuine match, counts
/// agree, unbounded results agree as multisets, and an `orderBy` stream is
/// correctly ordered.
///
/// ROUTING is proven separately with a ghost registry: the served capability
/// wired over an EMPTY scan source. A shape the composite planner serves
/// still answers from the index alone (rows > 0 despite the empty source);
/// a shape it must not serve answers empty (it fell back to the empty scan).
/// So a silent mis-route in either direction — the issue #45 under-fetch
/// class included — fails loudly instead of shipping wrong answers.

import { test } "mo:test";
import Nat        "mo:core/Nat";
import Int        "mo:core/Int";
import Float      "mo:core/Float";
import Bool       "mo:core/Bool";
import Text       "mo:core/Text";
import Array      "mo:core/Array";
import Iter       "mo:core/Iter";
import List       "mo:core/List";
import Map        "mo:core/Map";
import Option     "mo:core/Option";
import Order      "mo:core/Order";
import IndexedMap "../src/IndexedMap";
import Entity     "../src/Entity";
import OQL        "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _BoolValue "../src/BoolValue";
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";
import Executor   "../src/Executor";
import Query      "../src/Query";
import Predicate  "../src/Predicate";
import Registry   "../src/Registry";
import SecondaryIndex "../src/SecondaryIndex";

type Emp = { id : Nat; dept : Text; role : Text; salary : Nat };
type Txn = { id : Nat; kind : Text; amount : Nat };

let unrestricted : Executor.Access = func (_ : OQL.Decl) : OQL.Access = #unrestricted;

func cell(row : [Executor.Cell], name : Text) : ?OQL.Value {
  for (c in row.values()) { if (c.name == name) return ?c.value };
  null
};

// Same live data behind served and scan registries. `salary` TIES inside
// "eng" (three 60s) exercise ordering/pagination across equal keys; "ops"
// salaries are DISTINCT so keyset cursoring by last-seen salary is exact.
let staff : [Emp] = [
  { id = 1;  dept = "eng"; role = "dev"; salary = 50 },
  { id = 2;  dept = "eng"; role = "dev"; salary = 60 },
  { id = 3;  dept = "eng"; role = "ops"; salary = 60 },
  { id = 4;  dept = "eng"; role = "dev"; salary = 70 },
  { id = 5;  dept = "eng"; role = "qa";  salary = 80 },
  { id = 6;  dept = "eng"; role = "dev"; salary = 60 },
  { id = 7;  dept = "ops"; role = "dev"; salary = 40 },
  { id = 8;  dept = "ops"; role = "qa";  salary = 55 },
  { id = 9;  dept = "ops"; role = "dev"; salary = 65 },
  { id = 10; dept = "ops"; role = "ops"; salary = 75 },
  { id = 11; dept = "ops"; role = "dev"; salary = 85 },
  { id = 12; dept = "hr";  role = "qa";  salary = 90 },
  { id = 13; dept = "hr";  role = "dev"; salary = 90 },
];

// Two-column composite (dept, salary) plus one single-column index (role),
// so the planner's single- and multi-column routes coexist on one entity.
let emps = IndexedMap.newWith<Nat, Emp>([("role", #hash)], [(["dept", "salary"], #ordered)]);
// Three-column composite (dept, role, salary) over the same rows.
let emps3 = IndexedMap.newWith<Nat, Emp>([], [(["dept", "role", "salary"], #ordered)]);
for (e in staff.values()) { emps.put(e.id, e); emps3.put(e.id, e) };

let servedReg  = Registry.build([ emps.entity("emp", "Emp", "id").build() ]);
let servedReg3 = Registry.build([ emps3.entity("emp", "Emp", "id").build() ]);
let scanReg    = Registry.build([ Entity.new<Emp>("emp", func () = emps.values(), "Emp", "id").build() ]);

// ── comparison machinery ───────────────────────────────────────────────────

func valueKey(v : OQL.Value) : Text = switch v {
  case (#null_)   { "0" };
  case (#bool b)  { "1" # Bool.toText(b) };
  case (#nat n)   { "2" # Nat.toText(n) };
  case (#int i)   { "3" # Int.toText(i) };
  case (#float f) { "4" # Float.toText(f) };
  case (#text t)  { "5" # t };
};

// Order-independent identity of a row: its cells as name=value, name-sorted.
func rowKey(row : [Executor.Cell]) : Text {
  let parts = Array.map<Executor.Cell, Text>(row, func c = c.name # "=" # valueKey(c.value));
  var s = "";
  for (p in Array.sort(parts, Text.compare).values()) { s := s # p # "|" };
  s
};

func bag(rows : [[Executor.Cell]]) : Map.Map<Text, Nat> {
  let m = Map.empty<Text, Nat>();
  for (r in rows.values()) {
    let k = rowKey(r);
    m.add(Text.compare, k, 1 + Option.get(m.get(Text.compare, k), 0));
  };
  m
};

func flip(o : Order.Order) : Order.Order = switch o { case (#less) #greater; case (#equal) #equal; case (#greater) #less };

func cmpKeys(a : [Executor.Cell], b : [Executor.Cell], clauses : [Query.OrderBy]) : Order.Order {
  for (cl in clauses.values()) {
    let va = Option.get(cell(a, cl.field[0]), #null_);
    let vb = Option.get(cell(b, cl.field[0]), #null_);
    let raw = Predicate.compare(va, vb);
    let oriented = switch (cl.dir) { case (#asc) raw; case (#desc) flip(raw) };
    if (oriented != #equal) return oriented;
  };
  #equal
};

// The planner's SQL-semantics contract, with the plain-scan entity as truth.
func checkOn(served_ : Registry.Registry, q : Query.Query) : [[Executor.Cell]] {
  let served = Executor.runWith(served_, q, unrestricted).rows;
  let scan   = Executor.runWith(scanReg, q, unrestricted).rows;
  // Full (unbounded) match set — order-independent ground truth.
  let full   = Executor.runWith(scanReg, { q with limit = null; offset = null }, unrestricted).rows;

  assert served.size() == scan.size();                       // same count semantics

  let fullBag   = bag(full);
  let servedBag = bag(served);
  // Residual correctness: every served row is a genuine match.
  for ((k, c) in servedBag.entries()) { assert c <= Option.get(fullBag.get(Text.compare, k), 0) };
  // Unbounded ⇒ exactly the full match set.
  if (q.limit == null and q.offset == null) {
    assert servedBag.size() == fullBag.size();
    for ((k, c) in servedBag.entries()) { assert ?c == fullBag.get(Text.compare, k) };
  };
  // Ordered ⇒ served rows respect the orderBy.
  if (q.orderBy.size() > 0) {
    var i = 1;
    while (i < served.size()) { assert cmpKeys(served[i - 1], served[i], q.orderBy) != #greater; i += 1 };
  };
  served
};

func check(q : Query.Query) : [[Executor.Cell]] = checkOn(servedReg, q);

func q(where_ : ?Predicate.Predicate, orderBy : [Query.OrderBy], offset : ?Nat, limit : ?Nat) : Query.Query = {
  start = "emp"; where_; groupBy = []; aggregate = [];
  orderBy; offset; limit; select = null;
};

func eng(rest : [Predicate.Predicate]) : ?Predicate.Predicate =
  ?(#and_(Array.concat([#eq(["dept"], #text("eng"))] : [Predicate.Predicate], rest)));

// ── eq-prefix + range at the boundaries ─────────────────────────────────────

test("eq-prefix + range: inclusive/strict boundaries, empty above/below, empty prefix key", func () {
  assert check(q(eng([#ge(["salary"], #nat(50))]), [], null, null)).size() == 6;  // min boundary in
  assert check(q(eng([#gt(["salary"], #nat(50))]), [], null, null)).size() == 5;  // strict: residual drops the seek key
  assert check(q(eng([#ge(["salary"], #nat(60)), #le(["salary"], #nat(70))]), [], null, null)).size() == 4;
  assert check(q(eng([#gt(["salary"], #nat(80))]), [], null, null)).size() == 0;  // above the max
  assert check(q(eng([#lt(["salary"], #nat(50))]), [], null, null)).size() == 0;  // below the min
  assert check(q(?(#eq(["dept"], #text("zzz"))), [], null, null)).size() == 0;    // absent prefix key
});

test("full-length equality prefix (eq on every composite column)", func () {
  assert check(q(eng([#eq(["salary"], #nat(60))]), [], null, null)).size() == 3;  // the 60-tie
  assert check(q(eng([#eq(["salary"], #nat(51))]), [], null, null)).size() == 0;
});

test("bare one-column prefix (nothing on the next column)", func () {
  assert check(q(?(#eq(["dept"], #text("eng"))), [], null, null)).size() == 6;
});

// ── eq-prefix + orderBy, with TIES on the second column ─────────────────────

test("eq-prefix + orderBy salary asc/desc, ties included", func () {
  let asc = check(q(?(#eq(["dept"], #text("eng"))), [{ field = ["salary"]; dir = #asc }], null, null));
  assert asc.size() == 6;
  assert cell(asc[0], "salary") == ?(#nat(50));
  assert cell(asc[5], "salary") == ?(#nat(80));
  let desc = check(q(?(#eq(["dept"], #text("eng"))), [{ field = ["salary"]; dir = #desc }], null, null));
  assert cell(desc[0], "salary") == ?(#nat(80));
  assert cell(desc[5], "salary") == ?(#nat(50));
});

test("eq-prefix + orderBy + limit crossing a tie (top-N without sort)", func () {
  let r = check(q(?(#eq(["dept"], #text("eng"))), [{ field = ["salary"]; dir = #desc }], null, ?4));
  assert r.size() == 4;                                     // 80, 70, then two of the 60-tie
  assert cell(r[0], "salary") == ?(#nat(80));
  assert cell(r[3], "salary") == ?(#nat(60));
});

test("eq-prefix + bounds + orderBy pushed into one seek", func () {
  let r = check(q(eng([#ge(["salary"], #nat(55)), #le(["salary"], #nat(75))]),
                  [{ field = ["salary"]; dir = #desc }], null, null));
  assert r.size() == 4;                                     // 70, 60, 60, 60
  assert cell(r[0], "salary") == ?(#nat(70));
});

// ── keyset pagination ───────────────────────────────────────────────────────

test("offset pages compose to exactly the full ordered run", func () {
  let ord : [Query.OrderBy] = [{ field = ["salary"]; dir = #asc }];
  let full = check(q(?(#eq(["dept"], #text("eng"))), ord, null, null));
  let walked = List.empty<Text>();
  var offset = 0;
  loop {
    let page = check(q(?(#eq(["dept"], #text("eng"))), ord, ?offset, ?2));
    if (page.size() == 0) break;
    for (r in page.values()) { walked.add(rowKey(r)) };
    offset += 2;
    assert offset <= 20;   // liveness guard
  };
  let wa = walked.toArray();
  assert wa.size() == full.size();
  var i = 0;
  while (i < full.size()) { assert wa[i] == rowKey(full[i]); i += 1 };
});

test("keyset cursor by last-seen salary walks every row once, in order", func () {
  let ord : [Query.OrderBy] = [{ field = ["salary"]; dir = #asc }];
  let seen = List.empty<Nat>();
  var cursor : ?OQL.Value = null;
  loop {
    let where_ = switch cursor {
      case null { ?(#eq(["dept"], #text("ops")) : Predicate.Predicate) };
      case (?c) { ?(#and_([#eq(["dept"], #text("ops")), #gt(["salary"], c)]) : Predicate.Predicate) };
    };
    let page = check(q(where_, ord, null, ?2));
    if (page.size() == 0) break;
    for (r in page.values()) {
      switch (cell(r, "salary")) { case (?#nat(s)) { seen.add(s); cursor := ?(#nat(s)) }; case _ { assert false } };
    };
    assert seen.size() <= 10;   // liveness guard
  };
  assert Array.equal(seen.toArray(), [40, 55, 65, 75, 85], Nat.equal);   // exact walk, no skip, no repeat
});

// ── three-column composite: (eq, eq, range/orderBy) ─────────────────────────

func engDev(rest : [Predicate.Predicate]) : ?Predicate.Predicate =
  ?(#and_(Array.concat([#eq(["dept"], #text("eng")), #eq(["role"], #text("dev"))] : [Predicate.Predicate], rest)));

test("3-column composite: two-column eq prefix + range/orderBy on the third", func () {
  assert checkOn(servedReg3, q(engDev([#ge(["salary"], #nat(60))]), [], null, null)).size() == 3;  // 60, 60, 70
  assert checkOn(servedReg3, q(engDev([#le(["salary"], #nat(60))]), [], null, null)).size() == 3;  // 50, 60, 60
  assert checkOn(servedReg3, q(engDev([#ge(["salary"], #nat(55)), #le(["salary"], #nat(65))]), [], null, null)).size() == 2;
  let r = checkOn(servedReg3, q(engDev([]), [{ field = ["salary"]; dir = #desc }], null, null));
  assert r.size() == 4;
  assert cell(r[0], "salary") == ?(#nat(70));
  assert cell(r[3], "salary") == ?(#nat(50));
});

// ── declared order matters: non-prefix shapes fall back and stay correct ────

test("constraints that do not form a declared prefix fall back to scan, correctly", func () {
  assert check(q(?(#eq(["salary"], #nat(60))), [], null, null)).size() == 3;      // second column alone
  assert check(q(?(#ge(["salary"], #nat(80))), [], null, null)).size() == 4;      // range without the prefix
  assert check(q(?(#or_([#eq(["dept"], #text("eng")), #eq(["dept"], #text("hr"))])), [], null, null)).size() == 8;  // #or_ is opaque
  assert check(q(null, [{ field = ["salary"]; dir = #asc }], null, null)).size() == 13;  // orderBy the 2nd column alone
});

// ── routing proof: empty scan source, live composite index ──────────────────

// The served capability of `emps`, wired by hand (as `IndexedMap.entity`
// does) onto an entity whose scan source is EMPTY. Whatever this entity
// answers came from the index; whatever it cannot route answers empty.
func ghostServed(toPredRow : Emp -> Predicate.Row) : Entity.Served {
  func rows(refs : Iter.Iter<Nat>) : Iter.Iter<Predicate.Row> =
    refs.filterMap(func (k : Nat) : ?Predicate.Row =
      Option.map<Emp, Predicate.Row>(emps.get(k), toPredRow));
  {
    prune  = null;
    kindOf = func (col : Text) : ?SecondaryIndex.Kind = SecondaryIndex.kindOf(emps.ix, col);
    point  = func (col : Text, key : OQL.Value) : Iter.Iter<Predicate.Row> =
      rows(SecondaryIndex.point(emps.ix, col, key));
    points = func (col : Text, keys : [OQL.Value]) : Iter.Iter<Predicate.Row> =
      rows(SecondaryIndex.points(emps.ix, col, keys));
    range  = func (col : Text, lo : ?OQL.Value, hi : ?OQL.Value, dir : Entity.Dir) : Iter.Iter<Predicate.Row> =
      rows(SecondaryIndex.range(emps.ix, col, lo, hi, dir));
    composites = ?{
      decls = func () : [[Text]] = [["dept", "salary"]];
      range = func (cols : [Text], prefixEqs : [OQL.Value], lo : ?OQL.Value, hi : ?OQL.Value, dir : Entity.Dir) : Iter.Iter<Predicate.Row> =
        rows(SecondaryIndex.compositeRange(emps.ix, cols, prefixEqs, lo, hi, dir));
    };
    stats = null;
  }
};

let ghostReg = Registry.build([
  Entity.new<Emp>("emp", func () = ([] : [Emp]).values(), "Emp", "id")
    .sample({ id = 0; dept = "eng"; role = "dev"; salary = 0 })
    .withServed(ghostServed)
    .build()
]);

func ghost(qq : Query.Query) : Nat = Executor.runWith(ghostReg, qq, unrestricted).rows.size();

test("composite shapes route to the index (rows despite an empty scan source)", func () {
  assert ghost(q(eng([#ge(["salary"], #nat(60))]), [], null, null)) == 5;
  assert ghost(q(eng([#eq(["salary"], #nat(60))]), [], null, null)) == 3;   // full-length prefix
  assert ghost(q(?(#eq(["dept"], #text("eng"))), [{ field = ["salary"]; dir = #desc }], null, null)) == 6;
  assert ghost(q(?(#eq(["dept"], #text("eng"))), [], null, null)) == 6;     // bare prefix, last-resort route
  assert ghost(q(?(#eq(["role"], #text("dev"))), [], null, null)) == 8;     // single-column route still live
});

test("non-prefix shapes fall back to the (empty) scan — never the index", func () {
  assert ghost(q(?(#eq(["salary"], #nat(60))), [], null, null)) == 0;       // 2nd column alone: no prefix
  assert ghost(q(?(#ge(["salary"], #nat(0))), [], null, null)) == 0;        // range without the prefix
  assert ghost(q(null, [{ field = ["salary"]; dir = #asc }], null, null)) == 0;  // orderBy 2nd column alone
  assert ghost(q(?(#or_([#eq(["dept"], #text("eng")), #eq(["dept"], #text("hr"))])), [], null, null)) == 0;
  assert ghost(q(?(#eq(["id"], #nat(1))), [], null, null)) == 0;            // unindexed column
  assert ghost(q(?(#startsWith(["dept"], #text("e"))), [], null, null)) == 0;
});

// ── writes flow through: a key-vector-moving update + a delete ──────────────

test("composite postings track a dept+salary move and a delete", func () {
  emps.put(2, { id = 2; dept = "hr"; role = "dev"; salary = 95 });   // moves BOTH key columns
  emps.delete(5);                                                    // eng/qa/80 gone
  emps3.put(2, { id = 2; dept = "hr"; role = "dev"; salary = 95 });
  emps3.delete(5);

  assert check(q(?(#eq(["dept"], #text("eng"))), [], null, null)).size() == 4;
  assert check(q(eng([#eq(["salary"], #nat(60))]), [], null, null)).size() == 2;   // id 2 left the tie
  assert check(q(eng([#ge(["salary"], #nat(70))]), [], null, null)).size() == 1;   // id 5 gone
  assert check(q(?(#and_([#eq(["dept"], #text("hr")), #ge(["salary"], #nat(90))])), [], null, null)).size() == 3;
  let r = check(q(?(#eq(["dept"], #text("eng"))), [{ field = ["salary"]; dir = #desc }], null, null));
  assert r.size() == 4;
  assert cell(r[0], "salary") == ?(#nat(70));
  assert checkOn(servedReg3, q(engDev([#ge(["salary"], #nat(60))]), [], null, null)).size() == 2;
  // the ghost shares `emps`' live index: the moved row serves under its NEW prefix only
  assert ghost(q(?(#and_([#eq(["dept"], #text("hr")), #ge(["salary"], #nat(95))])), [], null, null)) == 1;
  assert ghost(q(eng([#eq(["salary"], #nat(80))]), [], null, null)) == 0;
});

// ── randomized differential oracle over the raw candidate API ───────────────

func kindName(n : Nat) : Text = if (n % 3 == 0) "burn" else if (n % 3 == 1) "mint" else "xfer";

func idsSorted(it : { next : () -> ?(Nat, Txn) }, pred : Txn -> Bool) : [Nat] {
  let acc = List.empty<Nat>();
  for ((k, r) in it) { if (pred(r)) acc.add(k) };
  Array.sort(acc.toArray(), Nat.compare)
};

func same(a : [Nat], b : [Nat]) : Bool = Array.equal(a, b, Nat.equal);

test("randomized differential oracle: composite index tracks the scan across put/delete", func () {
  let cols = ["kind", "amount"];
  let m = IndexedMap.newWith<Nat, Txn>([], [(cols, #ordered)]);

  var seed : Nat = 88_172_645;
  func rnd() : Nat { seed := (seed * 1_103_515_245 + 12_345) % 2_147_483_648; seed };

  let KEYS = 25;

  func chk(pred : Txn -> Bool, cand : { next : () -> ?(Nat, Txn) }) {
    assert same(idsSorted(m.entries(), pred), idsSorted(cand, pred));
  };

  var op = 0;
  while (op < 300) {
    let k = rnd() % KEYS;
    if (rnd() % 3 == 2) {
      m.delete(k);
    } else {
      m.put(k, { id = k; kind = kindName(rnd()); amount = rnd() % 60 });
    };

    chk(func r = r.kind == "burn",
        m.candidatesComposite(cols, [#text("burn")], null, null, #asc));
    chk(func r = r.kind == "burn" and r.amount >= 30,
        m.candidatesComposite(cols, [#text("burn")], ?#nat(30), null, #asc));
    chk(func r = r.kind == "mint" and r.amount >= 10 and r.amount <= 40,
        m.candidatesComposite(cols, [#text("mint")], ?#nat(10), ?#nat(40), #desc));
    chk(func r = r.kind == "xfer" and r.amount == 15,
        m.candidatesComposite(cols, [#text("xfer"), #nat(15)], null, null, #asc));

    op += 1;
  };

  // After the churn the full composite stream must be EXACTLY (kind asc,
  // amount asc, id asc) — and descending its mirror with id still asc within
  // a key (postings iterate in Ref order regardless of direction).
  let all = List.empty<(Nat, Txn)>();
  for (kv in m.entries()) { all.add(kv) };
  func byKey(desc : Bool) : [Nat] {
    let sorted = Array.sort<(Nat, Txn)>(all.toArray(), func ((k1, r1), (k2, r2)) : Order.Order {
      let kc = Text.compare(r1.kind, r2.kind);
      let key = switch kc { case (#equal) Nat.compare(r1.amount, r2.amount); case o o };
      switch (key, desc) {
        case (#equal, _) { Nat.compare(k1, k2) };
        case (o, false)  { o };
        case (o, true)   { flip(o) };
      };
    });
    Array.map<(Nat, Txn), Nat>(sorted, func ((k, _)) = k)
  };
  func streamed(dir : { #asc; #desc }) : [Nat] {
    let acc = List.empty<Nat>();
    for ((k, _) in m.candidatesComposite(cols, [], null, null, dir)) { acc.add(k) };
    acc.toArray()
  };
  assert same(streamed(#asc), byKey(false));
  assert same(streamed(#desc), byKey(true));
});
