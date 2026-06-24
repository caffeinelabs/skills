/// Query executor. Fixed pipeline:
///
///     where_ → (groupBy + aggregate) → orderBy → offset → limit → select
///
/// Operates over `Predicate.Row` values produced by `entity.rows()`,
/// wrapped with edge-aware lookup: a dotted path (`["dept","name"]`)
/// whose head is a declared `#edge` field traverses to the target entity
/// via a per-query primary-key hash index (left-join semantics). Returns
/// a typed `Result` for Candid serialisation on the way out.

import Array     "mo:core/Array";
import Bool      "mo:core/Bool";
import Float     "mo:core/Float";
import Int       "mo:core/Int";
import Iter      "mo:core/Iter";
import List      "mo:core/List";
import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Option    "mo:core/Option";
import Order     "mo:core/Order";
import Principal "mo:core/Principal";
import Runtime   "mo:core/Runtime";
import Auth      "Auth";
import Entity    "Entity";
import Predicate "Predicate";
import Query     "Query";
import Registry  "Registry";
import Schema    "Schema";
import Types     "Types";

module {

  type Value = Types.Value;
  type Path  = Types.Path;
  type Row   = Predicate.Row;

  public type Cell = { name : Text; value : Value };

  public type Result = {
    rows    : [[Cell]];
    hasMore : Bool;
  };

  /// The per-entity read decision for one query. Resolving access per
  /// `Entity.Decl` (rather than a single subject) is what lets entities
  /// carry different authorization levels: the mixin supplies
  /// `func d = Auth.resolve(d.auth, caller)`. There is deliberately no
  /// auth-bypassing convenience entry point — every run goes through
  /// `runWith` with an explicit resolver, so authorization can never be
  /// skipped by accident.
  public type Access = Entity.Decl -> Auth.Access;

  /// The query subject an `Access` scopes to: a concrete principal for
  /// `#scoped`, `null` (unrestricted) otherwise.
  func subjectOf(a : Auth.Access) : ?Principal =
    switch a { case (#scoped p) { ?p }; case _ { null } };

  /// Authorization-aware run. `access` decides, per entity, whether the
  /// caller may read it and at what scope. A denied start entity traps; a
  /// denied join target contributes an empty index, so traversal into it is
  /// a left-join null (no leak). Scoped entities — start AND join targets —
  /// yield only the rows their owner check admits for the resolved subject.
  public func runWith(r : Registry.Registry, q : Query.Query, access : Access) : Result {
    let entity = switch (Registry.lookup(r, q.start)) {
      case null { Runtime.trap("OQL: unknown entity '" # q.start # "'") };
      case (?d) { d };
    };

    let startSubject = switch (access(entity)) {
      case (#deny) { Runtime.trap("OQL: caller not allowed to read '" # entity.name # "'") };
      case (a) { subjectOf(a) };
    };

    let hops = collectHops(r, entity, q, access);
    let kept = filter(
      entity.rows(startSubject).map(func (row : Row) : Row = wrapRow(row, entity.name, hops)),
      q.where_,
    );

    // Aggregation stage: when grouping or aggregates are requested, collapse
    // the filtered rows into grouped rows; `defaultCols` then drives the
    // default projection (group keys + aggregate columns) instead of the
    // entity's own fields. Grouped rows are wrapped too, so an FK group key
    // still traverses (`groupBy: ["dept"], select: ["dept.name"]`).
    let (workRows, defaultCols) : ([Row], ?[Text]) =
      if (q.aggregate.size() == 0 and q.groupBy.size() == 0) { (kept, null) }
      else {
        let g = aggregateRows(kept, q.groupBy, q.aggregate);
        (g.rows.map(func (row : Row) : Row = wrapRow(row, entity.name, hops)), ?g.columns)
      };

    let sorted = if (q.orderBy.size() == 0) { workRows }
                 else { workRows.sort(makeComparator(q.orderBy)) };

    let offset  = q.offset.get(0);
    let limit   = q.limit.get(sorted.size());
    let endIdx  = if (offset > sorted.size()) { sorted.size() }
                  else { Nat.min(offset + limit, sorted.size()) };
    let window  = sorted.sliceToArray(offset, endIdx);
    let hasMore = endIdx < sorted.size();

    let paths = projectionPaths(q.select, entity.fields, defaultCols);
    let rows  = window.map(func (row : Row) : [Cell] = project(row, paths));

    { rows; hasMore };
  };

  // ── Edge traversal ──────────────────────────────────────────────────────

  /// Validated hops + per-target PK indexes for one query.
  type Hops = {
    edges   : Map.Map<Text, Text>;                // "<entity>\u{1f}<edge>" -> target entity
    indexes : Map.Map<Text, Map.Map<Text, Row>>;  // target entity -> PK index
  };

  /// Collect every dotted path in the query, validate each hop against the
  /// schema, and build one PK index per distinct target entity. Each
  /// target's index is built at its OWN resolved access: a denied target
  /// gets an empty index (every traversal into it is a left-join null), a
  /// scoped target only its caller-owned rows.
  func collectHops(r : Registry.Registry, start : Entity.Decl, q : Query.Query, access : Access) : Hops {
    let edges  = Map.empty<Text, Text>();
    let seen   = Map.empty<Text, ()>();
    let needed = List.empty<Entity.Decl>();

    for (path in queryPaths(q).values()) {
      if (path.size() > 5) {
        Runtime.trap("OQL: path '" # Types.pathToText(path) # "' exceeds 4 hops");
      };
      var entity = start;
      var i = 0;
      while (i + 1 < path.size()) {
        let target = validateHop(r, entity, path[i]);
        edges.add(entity.name # "\u{1f}" # path[i], target.name);
        if (seen.get(target.name) == null) {
          seen.add(target.name, ());
          needed.add(target);
        };
        entity := target;
        i += 1;
      };
    };

    let indexes = Map.empty<Text, Map.Map<Text, Row>>();
    for (decl in needed.values()) {
      let idx = switch (access(decl)) {
        case (#deny) { Map.empty<Text, Row>() };  // denied target -> left-join null
        case (a)     { buildIndex(decl, subjectOf(a)) };
      };
      indexes.add(decl.name, idx);
    };
    { edges; indexes }
  };

  /// Every field path referenced anywhere in the query.
  func queryPaths(q : Query.Query) : [Path] {
    let acc = List.empty<Path>();
    func fromPred(p : Predicate.Predicate) {
      switch p {
        case (#eq(path, _) or #ne(path, _) or #lt(path, _) or #le(path, _)
           or #gt(path, _) or #ge(path, _) or #contains(path, _)
           or #icontains(path, _) or #startsWith(path, _) or #endsWith(path, _)) {
          acc.add(path)
        };
        case (#in_(path, _)) { acc.add(path) };
        case (#and_ ps) { for (x in ps.values()) fromPred(x) };
        case (#or_  ps) { for (x in ps.values()) fromPred(x) };
        case (#not_ x)  { fromPred(x) };
      };
    };
    switch (q.where_) { case (?p) { fromPred(p) }; case null {} };
    for (ob in q.orderBy.values()) acc.add(ob.field);
    for (g in q.groupBy.values()) acc.add(g);
    for (a in q.aggregate.values()) {
      switch (a.field) { case (?p) { acc.add(p) }; case null {} };
    };
    switch (q.select) {
      case (?ps) { for (p in ps.values()) acc.add(p) };
      case null {};
    };
    acc.toArray()
  };

  /// One hop: `edge` on `entity` must be a declared `#edge` whose target is
  /// registered, exposes its primary key, and is join-compatible. A target
  /// with no seed (`fields == []`) skips the PK/type checks — its index is
  /// empty and every traversal is a left-join null.
  func validateHop(r : Registry.Registry, entity : Entity.Decl, edge : Text) : Entity.Decl {
    let fld = switch (entity.fields.find(func f = f.name == edge)) {
      case (?f) { f };
      case null { Runtime.trap("OQL: '" # edge # "' is not an edge of '" # entity.name # "'") };
    };
    let to = switch (fld.role) {
      case (#edge e) { e.to };
      case _ { Runtime.trap("OQL: '" # edge # "' is not an edge of '" # entity.name # "'") };
    };
    let target = switch (Registry.lookup(r, to)) {
      case (?t) { t };
      case null {
        Runtime.trap("OQL: edge '" # entity.name # "." # edge
          # "' targets unknown entity '" # to # "'")
      };
    };
    if (target.fields.size() > 0) {
      let pk = switch (target.fields.find(func f = f.name == target.primaryKey)) {
        case (?f) { f };
        case null {
          Runtime.trap("OQL: cannot expand into '" # target.name # "' — primary key '"
            # target.primaryKey # "' is hidden or absent")
        };
      };
      if (not joinable(fld.typeName, pk.typeName)) {
        Runtime.trap("OQL: cannot join '" # entity.name # "." # edge # "' ("
          # fld.typeName # ") to '" # target.name # "." # target.primaryKey
          # "' (" # pk.typeName # ")");
      };
    };
    target
  };

  /// Exact, stable equality only: Text, Bool, and Nat/Int (bridged like
  /// `compare`). Float is rejected. "Null" means the seed row's value was
  /// null — type unknown, defer to runtime where `joinKey` stays total.
  func joinable(fk : Text, pk : Text) : Bool {
    func num(t : Text) : Bool = t == "Nat" or t == "Int";
    if (fk == "Null" or pk == "Null") return true;
    (fk == "Text" and pk == "Text") or (fk == "Bool" and pk == "Bool")
      or (num(fk) and num(pk))
  };

  /// Join-key encoding. Deliberately NOT `valueKey`: its type-tagging is
  /// correct for groupBy buckets and fatal here, where FK and PK may arrive
  /// as different numeric variants that `compare` treats as equal.
  /// Float/null are unjoinable -> null -> left-join.
  func joinKey(v : Value) : ?Text = switch v {
    case (#text t) { ?("t:" # t) };
    case (#nat n)  { ?("i:" # Nat.toText(n)) };  // == Int.toText(n) for n >= 0
    case (#int i)  { ?("i:" # Int.toText(i)) };
    case (#bool b) { ?("b:" # Bool.toText(b)) };
    case _ { null };
  };

  func buildIndex(decl : Entity.Decl, subject : ?Principal) : Map.Map<Text, Row> {
    let idx = Map.empty<Text, Row>();
    for (row in decl.rows(subject)) {
      switch (joinKey(row.get([decl.primaryKey]).get(#null_))) {
        case (?k) { idx.add(k, row) };
        case null {
          Runtime.trap("OQL: row of '" # decl.name # "' has no joinable primary key '"
            # decl.primaryKey # "'")
        };
      };
    };
    idx
  };

  /// Edge-aware row view: base-first, traverse-on-miss. Plain rows answer
  /// null for multi-segment paths (`Entity.makeRow`), so they always fall
  /// through to traversal; aggregated rows resolve their flat dotted group
  /// columns locally and only traverse from FK group keys.
  func wrapRow(base : Row, entityName : Text, hops : Hops) : Row = {
    get = func (path : Path) : ?Value {
      switch (base.get(path)) {
        case (?v) { ?v };
        case null {
          if (path.size() < 2) return null;
          let target = switch (hops.edges.get(entityName # "\u{1f}" # path[0])) {
            case (?t) { t };
            case null { return null };
          };
          let idx = switch (hops.indexes.get(target)) {
            case (?i) { i };
            case null { return null };
          };
          let fk = switch (base.get([path[0]])) {
            case (?v) { v };
            case null { return null };
          };
          switch (joinKey(fk)) {
            case null { null };                 // null FK -> left-join null
            case (?k) {
              switch (idx.get(k)) {
                case null { null };             // dangling FK -> left-join null
                case (?t) { wrapRow(t, target, hops).get(path.sliceToArray(1, path.size())) };
              };
            };
          };
        };
      };
    };
  };

  func filter(it : Iter.Iter<Row>, where_ : ?Predicate.Predicate) : [Row] =
    switch where_ {
      case null { it.toArray() };
      case (?p) { it.filter(func row = Predicate.eval(p, row)).toArray() };
    };

  func project(row : Row, paths : [Path]) : [Cell] =
    paths.map(func (p : Path) : Cell = {
      name  = Types.pathToText(p);
      value = row.get(p).get(#null_);
    });

  /// Explicit `select` wins. Otherwise: for aggregated results project the
  /// group-key + aggregate columns; for plain results project every
  /// non-hidden field in declaration order (hidden fields are already
  /// absent from the row).
  func projectionPaths(sel : ?[Path], all : [Schema.FieldDecl], defaultCols : ?[Text]) : [Path] =
    switch sel {
      case (?p) { p };
      case null {
        switch defaultCols {
          case (?cols) { cols.map(func (c : Text) : Path = [c]) };
          case null {
            all.filter(func f = switch (f.role) { case (#hidden) false; case _ true })
               .map(func (f : Schema.FieldDecl) : Path = [f.name])
          };
        }
      };
    };

  func makeComparator(clauses : [Query.OrderBy]) : (Row, Row) -> Order.Order =
    func (a, b) {
      for (c in clauses.values()) {
        let raw = Predicate.compare(
          a.get(c.field).get(#null_),
          b.get(c.field).get(#null_),
        );
        let oriented = switch (c.dir) { case (#asc) raw; case (#desc) flip(raw) };
        if (oriented != #equal) return oriented;
      };
      #equal
    };

  func flip(o : Order.Order) : Order.Order = switch o {
    case (#less)    { #greater };
    case (#equal)   { #equal };
    case (#greater) { #less };
  };

  // ── Aggregation ─────────────────────────────────────────────────────────

  type Group = { keyCells : [(Text, Value)]; members : List.List<Row> };

  /// Bucket `rows` by the `groupBy` keys and collapse each bucket to one
  /// output row: the group-key cells followed by one cell per aggregate.
  /// With no `groupBy` but aggregates present, emits a single row over all
  /// rows (so `count` of an empty set is `0`). Group order is first-seen.
  func aggregateRows(rows : [Row], groupBy : [Path], aggs : [Agg])
    : { rows : [Row]; columns : [Text] } {

    let columns = groupBy.map(Types.pathToText).concat(aggs.map(aggName));

    // One output row: the group's key cells plus one cell per aggregate.
    func aggRow(keyCells : [(Text, Value)], members : [Row]) : Row {
      let aggCells = Array.map<Agg, (Text, Value)>(aggs, func a = (aggName(a), computeAgg(a, members)));
      rowOf(keyCells.concat(aggCells))
    };

    if (groupBy.size() == 0) return { rows = [aggRow([], rows)]; columns };

    let groups = Map.empty<Text, Group>();
    let order  = List.empty<Text>();
    for (row in rows.values()) {
      let keyVals = groupBy.map(func (p : Path) : Value = row.get(p).get(#null_));
      let key = groupKey(keyVals);
      switch (groups.get(key)) {
        case (?g) { g.members.add(row) };
        case null {
          let keyCells = Array.tabulate<(Text, Value)>(
            groupBy.size(),
            func i = (Types.pathToText(groupBy[i]), keyVals[i]),
          );
          let g : Group = { keyCells; members = List.empty<Row>() };
          g.members.add(row);
          groups.add(key, g);
          order.add(key);
        };
      };
    };

    let out = List.empty<Row>();
    for (key in order.values()) {
      let g = switch (groups.get(key)) { case (?x) x; case null { Runtime.trap("OQL: group vanished") } };
      out.add(aggRow(g.keyCells, g.members.toArray()));
    };
    { rows = out.toArray(); columns };
  };

  type Agg = Query.Agg;

  /// Output column for an aggregate. Defaults join path segments with
  /// `_` (not `.`): a dotted default like `sum_dept.budget` would parse
  /// as an edge path on any later reference and trap.
  func aggName(a : Agg) : Text = switch (a.as_) {
    case (?n) { n };
    case null {
      let base = switch (a.fn) {
        case (#count) "count"; case (#sum) "sum"; case (#avg) "avg";
        case (#min) "min";     case (#max) "max";
      };
      switch (a.field) { case null { base }; case (?p) { base # "_" # p.values().join("_") } };
    };
  };

  func computeAgg(a : Agg, members : [Row]) : Value =
    switch (a.fn) {
      case (#count) { #nat(members.size()) };
      case (#sum)   { sumOf(fieldValues(a.field, members)) };
      case (#avg)   { avgOf(fieldValues(a.field, members)) };
      case (#min)   { extremeOf(fieldValues(a.field, members), true) };
      case (#max)   { extremeOf(fieldValues(a.field, members), false) };
    };

  /// Non-null values at `field` across `members`.
  func fieldValues(field : ?Path, members : [Row]) : [Value] {
    switch field {
      case null { [] };
      case (?p) {
        let acc = List.empty<Value>();
        for (row in members.values()) {
          switch (row.get(p)) { case (?v) { if (v != #null_) acc.add(v) }; case null {} };
        };
        acc.toArray()
      };
    };
  };

  func sumOf(vals : [Value]) : Value {
    var acc : Value = #nat(0);
    for (v in vals.values()) acc := numAdd(acc, v);
    acc
  };

  func avgOf(vals : [Value]) : Value {
    if (vals.size() == 0) return #null_;
    #float(toFloat(sumOf(vals)) / Float.fromInt(vals.size()))
  };

  /// `wantMin = true` → minimum; otherwise maximum. Uses `Predicate.compare`
  /// so numeric variants bridge and text compares lexicographically.
  func extremeOf(vals : [Value], wantMin : Bool) : Value {
    if (vals.size() == 0) return #null_;
    var acc = vals[0];
    var i = 1;
    while (i < vals.size()) {
      let c = Predicate.compare(vals[i], acc);
      if ((wantMin and c == #less) or (not wantMin and c == #greater)) acc := vals[i];
      i += 1;
    };
    acc
  };

  /// Numeric addition promoting Nat → Int → Float; non-numeric `b` is a no-op.
  func numAdd(a : Value, b : Value) : Value =
    switch (a, b) {
      case (#float x, _) { #float(x + toFloat(b)) };
      case (_, #float y) { #float(toFloat(a) + y) };
      case (#int x, _)   { #int(x + toInt(b)) };
      case (_, #int y)   { #int(toInt(a) + y) };
      case (#nat x, #nat y) { #nat(x + y) };
      case _ { a };
    };

  func toFloat(v : Value) : Float = switch v {
    case (#float f) { f }; case (#int i) { Float.fromInt(i) };
    case (#nat n)   { Float.fromInt(n) }; case _ { 0.0 };
  };

  func toInt(v : Value) : Int = switch v {
    case (#int i) { i }; case (#nat n) { n }; case _ { 0 };
  };

  /// Synthetic row for aggregated results. Keys on the rendered path text
  /// so a dotted group column (`"dept.name"`) is reachable both as the
  /// single-segment default-projection path and as the parsed
  /// `["dept","name"]` from orderBy/select.
  func rowOf(cells : [(Text, Value)]) : Row {
    let m = Map.empty<Text, Value>();
    for ((k, v) in cells.values()) m.add(k, v);
    { get = func (p : Path) : ?Value = if (p.size() == 0) null else m.get(Types.pathToText(p)) }
  };

  /// Type-tagged serialisation of the group-key tuple, so distinct values
  /// (and distinct types) never collide into the same bucket.
  func groupKey(vals : [Value]) : Text {
    var s = "";
    for (v in vals.values()) s := s # valueKey(v) # "\u{1f}";
    s
  };

  func valueKey(v : Value) : Text = switch v {
    case (#null_)   { "0:" };
    case (#bool b)  { "1:" # Bool.toText(b) };
    case (#nat n)   { "2:" # Nat.toText(n) };
    case (#int i)   { "3:" # Int.toText(i) };
    case (#float f) { "4:" # Float.toText(f) };
    case (#text t)  { "5:" # t };
  };

};
