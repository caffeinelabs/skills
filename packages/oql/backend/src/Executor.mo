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
import Text      "mo:core/Text";
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
  public func runWith(r : Registry.Registry, qArg : Query.Query, access : Access) : Result {
    let ?entity = Registry.lookup(r, qArg.start) else Runtime.trap("OQL: unknown entity '" # qArg.start # "'");

    let resolved = switch (access(entity)) {
      case (#deny) { Runtime.trap("OQL: caller not allowed to read '" # entity.name # "'") };
      case (a) { subjectOf(a) };
    };

    // A scoped read of an `.ownedBy` entity is the same query an unrestricted
    // caller would run with `owner == me` added: `ownerIsCaller` tests exactly
    // that equality, so the rewrite is semantically identical. Running it
    // unrestricted lets the planner serve it from the owner index (count off the
    // stats, rows by seek) instead of scanning; the predicate stays in `where_`,
    // so the residual re-applies it on every path and no unscoped row or
    // aggregate can leak. Only `scopeKey`-eligible entities take this path —
    // custom `.ownedByWith`, `.viewWith`, and self-scoping sources keep the scan.
    let (q, startSubject) = switch (resolved, entity.scopeKey) {
      case (?p, ?f) {
        let own : Predicate.Predicate = #eq([f], #text(p.toText()));
        let where_ = switch (qArg.where_) { case (?w) ?#and_([own, w]); case null ?own };
        ({ qArg with where_ }, null);
      };
      case _ { (qArg, resolved) };
    };

    // The ownership check as a per-row guard, for scoped reads of entities that
    // expose one (`Decl.admits`: custom `.ownedByWith`, or `.ownedBy` when the
    // rewrite above did not fire). Non-null exactly when a plan's superset
    // stream must be re-scoped; applied at the `filter` choke point below, so
    // no planner branch can bypass it.
    let scopedAdmit : ?(Row -> Bool) = switch (startSubject, entity.admits) {
      case (?p, ?adm) ?(func (r : Row) : Bool = adm(p, r));
      case _ null;
    };

    // Index-served aggregate: answer count / min / max / group-count straight
    // off the index stats, with no scan. Unrestricted callers only — the stats
    // aggregate EVERY owner's rows and a served scalar cannot be post-filtered,
    // so a scoped read (even one with an `admits` guard) never lands here; its
    // aggregates fold over the admitted stream below. Exact cases only, so the
    // result equals a scan of the query.
    switch (startSubject, entity.served) {
      case (null, ?s) {
        switch (aggPlan(s, q)) {
          case (?(rows, cols)) { return finishRows(rows, ?cols, false, q, entity.fields) };
          case null {};
        };
      };
      case _ {};
    };

    let hops = collectHops(r, entity, q, access);
    // Every dotted path is validated into `hops.edges` (collectHops traps on
    // an invalid hop), so this is also the cheapest gate for join planning.
    let hasEdges = hops.edges.size() > 0;

    // Planner: try to serve the row source from the entity's maintained index
    // instead of scanning. `served` rows bypass the owner/view scoping
    // `makeRows` applies, so we plan only when the subject is `null`
    // (unrestricted — the `.ownedBy` rewrite above resolves to this too) or
    // when the entity exposes its ownership check as a per-row predicate
    // (`admits`), which the residual choke point below re-applies to every
    // planned or pruned row — a plan never bypasses scoping. `.viewWith`
    // entities and subject-honouring (`newScoped`) sources have no `admits`
    // and keep the scan; a `newScoped` scan is already O(subject rows) by
    // construction — the source itself is subject-keyed. A plan yields a
    // SUPERSET (the residual `where_` still runs below); `ordered` says the
    // stream already satisfies `orderBy`, so the sort is skipped and the scan
    // cap applies even with `orderBy` present.
    // `residual` is the predicate still to apply after the plan narrows the
    // stream. A `planServed` plan is only a SUPERSET, so its residual is the
    // whole `where_`. A `planJoin` semi-join is EXACT for the edge-filter
    // conjunct it serves (see planJoin), so it drops that conjunct — which is
    // what lets the dimension index stay unbuilt when nothing else traverses.
    let plan : ?Plan =
      switch (if (startSubject == null or scopedAdmit.isSome()) entity.served else null) {
        case (?s) {
          let cs = conjuncts(q.where_);
          switch (planServed(s, q, cs)) {
            case (?p) {
              let own : Plan = {
                rows = p.rows;
                ordered = p.ordered;
                residual = q.where_;
              };
              // A direct equality used to win unconditionally, even when its
              // posting was far larger than an available semi-join. Compare
              // exact counts and proven lower bounds; an uncertain comparison
              // keeps the established direct-source priority.
              switch (p.direct) {
                case (?(col, value)) {
                  if (not hasEdges) {
                    ?own
                  } else {
                    switch (pointCountForPlan(s, col, value)) {
                      case (?ownCount) switch ownCount {
                        case (#exact(0)) ?own;
                        case (#exact n) {
                          let candidateLimit = n - 1;
                          switch (planJoin(hops, r, entity, s, q, access, cs, true, candidateLimit)) {
                            case (?join) {
                              switch (join.candidates) {
                                case (?joinCount) {
                                  if (joinProvenSmaller(joinCount, ownCount)) {
                                    ?{ rows = join.rows; ordered = join.ordered; residual = join.residual }
                                  } else {
                                    ?own
                                  }
                                };
                                case null { ?own };
                              };
                            };
                            case null { ?own };
                          };
                        };
                        case (#atLeast n) {
                          let candidateLimit = if (n == 0) 0 else n - 1;
                          switch (planJoin(hops, r, entity, s, q, access, cs, true, candidateLimit)) {
                            case (?join) {
                              switch (join.candidates) {
                                case (?joinCount) {
                                  if (joinProvenSmaller(joinCount, ownCount)) {
                                    ?{ rows = join.rows; ordered = join.ordered; residual = join.residual }
                                  } else {
                                    ?own
                                  }
                                };
                                case null { ?own };
                              };
                            };
                            case null { ?own };
                          };
                        };
                      };
                      case null { ?own };
                    };
                  };
                };
                case null { ?own };
              };
            };
            case null {
              switch (planJoin(hops, r, entity, s, q, access, cs, false, 0)) {
                case (?join) ?{ rows = join.rows; ordered = join.ordered; residual = join.residual };
                case null null;
              }
            }; // else a semi-join on an edge filter
          }
        };
        case null { null };
      };
    let planOrdered = switch plan { case (?pl) pl.ordered; case null false };
    let residualPred = switch plan { case (?pl) pl.residual; case null q.where_ };

    // With no ordering or aggregation, the result is just the first
    // `offset+limit` survivors in scan order — so stop scanning there instead
    // of materialising the whole table (+1 to still detect `hasMore`). An
    // index-ordered plan is already in `orderBy` order, so the same early stop
    // applies even when `orderBy` is present. With no limit, or when
    // aggregation is present, every row is needed. The window/`hasMore` logic
    // below is unchanged and yields identical results.
    let scanCap : ?Nat =
      if ((q.orderBy.size() == 0 or planOrdered) and q.aggregate.size() == 0 and q.groupBy.size() == 0) {
        switch (q.limit) { case (?lim) { ?((q.offset ?? 0) + lim + 1) }; case null { null } };
      } else { null };

    // An empty `edges` means `wrapRow` would be a pure pass-through. Skip it to
    // save a per-row closure allocation on the common join-free query.
    // Scan fall-back: prefer a backend's zone-map-pruned scan when it offers
    // one. The pruned scan ignores the owner subject, so it serves an
    // unrestricted read as-is and an admits-guarded scoped read with the guard
    // attached; any other scoped read keeps `entity.rows(?p)`, whose `makeRows`
    // applies the scoping itself. The result is a superset; `filter` below
    // still applies the full predicate (and the guard).
    let (baseRows, admitGuard) : (Iter.Iter<Row>, ?(Row -> Bool)) = switch plan {
      case (?pl) (pl.rows, scopedAdmit);   // a plan bypasses makeRows → guard
      case null {
        let pr = switch (entity.served) { case (?s) s.prune; case null null };
        switch (pr, scopedAdmit, startSubject) {
          case (?prune, _, null) (prune(q.where_), null);
          case (?prune, ?g, ?_)  (prune(q.where_), ?g);
          case _                 (entity.rows(startSubject), null);
        };
      };
    };
    let kept = filter(
      if (hasEdges) { baseRows.map(func (row : Row) : Row = wrapRow(row, entity.name, hops)) }
      else          { baseRows },
      residualPred,
      admitGuard,
      scanCap,
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
        let gr = if (hasEdges) { g.rows.map(func (row : Row) : Row = wrapRow(row, entity.name, hops)) }
                 else          { g.rows };
        (gr, ?g.columns)
      };

    finishRows(workRows, defaultCols, planOrdered, q, entity.fields)
  };

  /// The tail shared by the scan pipeline and the index-served aggregate path:
  /// order → offset/limit window → project. `planOrdered` skips the sort when
  /// the rows already arrive in `orderBy` order.
  func finishRows(workRows : [Row], defaultCols : ?[Text], planOrdered : Bool, q : Query.Query, fields : [Schema.FieldDecl]) : Result {
    let sorted = if (q.orderBy.size() == 0 or planOrdered) { workRows }
                 else { sortByKeys(workRows, q.orderBy) };

    let offset  = q.offset ?? 0;
    let limit   = q.limit.get(sorted.size());
    let endIdx  = if (offset > sorted.size()) { sorted.size() }
                  else { Nat.min(offset + limit, sorted.size()) };
    let window  = sorted.sliceToArray(offset, endIdx);
    let hasMore = endIdx < sorted.size();

    let paths = projectionPaths(q.select, fields, defaultCols);
    // Column names + flat slots are identical across rows — resolve them once,
    // not per cell per row.
    let names = paths.map(Types.pathToText);
    let slots = resolveSlots(if (window.size() == 0) null else ?window[0], paths);
    let rows  = window.map(func (row : Row) : [Cell] = project(row, paths, names, slots));

    { rows; hasMore }
  };

  /// Answer a single aggregate from the index's stats — no row scan — as the
  /// synthetic aggregated rows + their column names (the shape `aggregateRows`
  /// produces), or `null` to fall back to the scan. Served ONLY when the whole
  /// query is expressible as an exact stat (no residual `where`), so the answer
  /// equals a scan's:
  ///   - `groupBy [col]` + `count(*)`, no `where` → the per-value histogram;
  ///   - `count(*)` with no `where` → the row count; with a lone `#eq` on an
  ///     indexed column → that posting's size;
  ///   - `min(col)` / `max(col)`, no `where`, `col` `#ordered`-indexed → the
  ///     extreme non-null value.
  /// Everything else (sum/avg, multi-aggregate, residual predicates, non-indexed
  /// or `#hash` min/max) returns `null`. `orderBy`/`limit`/`select` are applied
  /// by `finishRows` over the synthetic rows, exactly as for the scan path.
  func aggPlan(s : Entity.Served, q : Query.Query) : ?([Row], [Text]) {
    if (q.aggregate.size() != 1) return null;
    let ?st = s.stats else return null;
    let a = q.aggregate[0];
    let name = aggName(a);

    // groupBy <indexed col> + count(*), no where → the histogram.
    if (q.groupBy.size() == 1 and q.where_ == null and a.fn == #count and a.field == null and q.groupBy[0].size() == 1) {
      let col = q.groupBy[0][0];
      switch (st.groupCount(col)) {
        case (?pairs) {
          let out = List.empty<Row>();
          for ((v, n) in pairs) { out.add(rowOf([(col, v), (name, #nat(n))])) };
          return ?(out.toArray(), [col, name]);
        };
        case null { return null };
      };
    };

    // no groupBy → a single scalar aggregate row.
    if (q.groupBy.size() == 0) {
      switch (a.fn, a.field) {
        case (#count, null) {
          let cs = conjuncts(q.where_);
          if (cs.size() == 0) { return ?([rowOf([(name, #nat(st.total()))])], [name]) };
          if (cs.size() == 1) {
            switch (cs[0]) {
              case (#eq(p, v)) {
                if (p.size() == 1) {
                  switch (st.count(p[0], v)) { case (?n) { return ?([rowOf([(name, #nat(n))])], [name]) }; case null {} };
                };
              };
              case _ {};
            };
          };
          return null;
        };
        case ((#min or #max), ?p) {
          if (q.where_ == null and p.size() == 1 and (s.kindOf(p[0]) == ?#ordered or st.extremesExact(p[0]))) {
            let v = switch (a.fn) { case (#min) { st.min(p[0]) }; case _ { st.max(p[0]) } };
            return ?([rowOf([(name, v ?? #null_)])], [name]);
          };
          return null;
        };
        case ((#sum or #avg), ?p) {
          // Whole-column sum/avg with no predicate: serve from the backend's
          // running sum (and non-null count, for avg) if it maintains them
          // (e.g. columnar footers); otherwise fall back to the scan-fold.
          if (q.where_ == null and p.size() == 1) {
            let v = switch (a.fn) { case (#sum) { st.sum(p[0]) }; case _ { st.avg(p[0]) } };
            switch v { case (?x) { return ?([rowOf([(name, x)])], [name]) }; case null {} };
          };
          return null;
        };
        case _ { return null };
      };
    };
    null
  };

  // ── Planner ───────────────────────────────────────────────────────────────

  type Plan = {
    rows : Iter.Iter<Row>;
    ordered : Bool;
    residual : ?Predicate.Predicate;
  };

  type JoinPlan = {
    rows : Iter.Iter<Row>;
    ordered : Bool;
    residual : ?Predicate.Predicate;
    candidates : ?Entity.CountEstimate;
  };

  // Initial budget for a genuinely expensive count (currently only a Table's
  // uncovered mid-upload tail). Cheap heap and covered-region counts ignore it
  // and remain exact at any cardinality.
  let PLAN_COUNT_CAP = 10_000;

  /// Candidate counts below measure SOURCE superset sizes (pre-`admits`), a
  /// work proxy for choosing the cheaper stream — never a result count.
  ///
  /// Pick an index access for `q` against the entity's `served` capability, or
  /// `null` to scan. Every plan yields a SUPERSET; the executor re-applies the
  /// full `where_` as a residual filter, so a plan only ever changes speed. Row
  /// order follows SQL semantics: an explicit `orderBy` is honoured (the
  /// executor sorts the superset unless the plan is already in that order), and
  /// without one the result order — including which rows a bare `limit` keeps —
  /// is unspecified, which is what lets an unordered range/`#in_` stream serve.
  ///
  /// Shapes, in priority order (a heuristic, not a cost model):
  ///   1. An equality PREFIX over a declared composite plus something pushed
  ///      onto the NEXT column — a range bound, a single-field `orderBy`
  ///      (direction from the clause, `ordered = true` so top-N applies), a
  ///      second pinned column, or a full-length prefix → one contiguous
  ///      composite seek, the narrowest superset (every prefix column pins a
  ///      key element).
  ///   2. `#eq` on an indexed column (through top-level `#and_`) → point probe:
  ///      the narrowest single-column superset, posting order = scan order.
  ///   3. Single-field `orderBy` on an `#ordered` column (no grouping /
  ///      aggregation) → ordered range in the requested direction, with any
  ///      `where_` bounds on that column pushed into the seek. `ordered = true`
  ///      lets the executor skip the sort and stop at `offset+limit` (top-N).
  ///   4. `#in_` on an indexed column → the union of its point probes.
  ///   5. A range (`#lt`/`#le`/`#gt`/`#ge`) on an indexed column → the bounded
  ///      range (inclusive; strict bounds handled by the residual filter).
  ///   6. A bare one-column composite prefix (`#eq` on the leading column of a
  ///      composite, nothing pushed further) — last, because a single-column
  ///      shape serves the same constraint from a narrower posting; this only
  ///      routes what would otherwise scan.
  ///
  /// Only `#eq`/`#in_`/range constraints reachable through top-level `#and_`
  /// drive — the same predicate under `#or_`/`#not_` is not a superset of the
  /// query's matches. Everything else scans.
  func planServed(s : Entity.Served, q : Query.Query, cs : [Predicate.Predicate])
    : ?{ rows : Iter.Iter<Row>; ordered : Bool; direct : ?(Text, Value) } {
    let comp = switch (s.composites) { case (?c) { planComposite(c, cs, q) }; case null { null } };
    switch comp {
      case (?p) { if (p.pushed) return ?{ rows = p.rows; ordered = p.ordered; direct = null } };
      case null {};
    };
    switch (findEq(cs, s)) {
      case (?(col, v)) {
        return ?{
          rows = s.point(col, v);
          ordered = false;
          direct = ?(col, v);
        }
      };
      case null {};
    };
    if (q.aggregate.size() == 0 and q.groupBy.size() == 0
        and q.orderBy.size() == 1 and q.orderBy[0].field.size() == 1) {
      let col = q.orderBy[0].field[0];
      if (s.kindOf(col) == ?#ordered) {
        let (lo, hi) = boundsFor(cs, col);
        return ?{ rows = s.range(col, lo, hi, q.orderBy[0].dir); ordered = true; direct = null };
      };
    };
    switch (findIn(cs, s)) {
      case (?(col, vs)) { return ?{ rows = s.points(col, vs); ordered = false; direct = null } };
      case null {};
    };
    switch (findRangeCol(cs, s)) {
      case (?col) {
        let (lo, hi) = boundsFor(cs, col);
        return ?{ rows = s.range(col, lo, hi, #asc); ordered = false; direct = null }
      };
      case null {};
    };
    switch comp {
      case (?p) { return ?{ rows = p.rows; ordered = p.ordered; direct = null } };
      case null {};
    };
    null
  };

  /// Cheap stores return an exact count at any size. A Table with an uncovered
  /// tail scans only until this initial budget is exceeded and returns the
  /// lower bound it proved.
  func pointCountForPlan(s : Entity.Served, col : Text, v : Value) : ?Entity.CountEstimate =
    switch (s.stats) {
      case (?st) st.countUpTo(col, v, PLAN_COUNT_CAP - 1);
      case null null;
    };

  func joinProvenSmaller(join : Entity.CountEstimate, own : Entity.CountEstimate) : Bool =
    switch (join, own) {
      case (#exact j, #exact o) j < o;
      case (#exact j, #atLeast o) j < o;
      case _ false;
    };

  /// Composite plan for one query. Per declared composite, the longest
  /// equality prefix the top-level conjuncts pin (in the DECLARED column
  /// order — an `#eq` on a later column without its prefix cannot seek, the
  /// gate that keeps issue #45's silent under-fetch impossible), plus at most
  /// one range / single-field `orderBy` pushed onto the NEXT column.
  /// `pushed` reports whether the match drives more than a bare single-column
  /// `#eq` would — that is what ranks it against the single-column shapes.
  /// The first declaration with a pushed match wins; a bare one-column prefix
  /// is remembered as the last-resort route. No prefix → no composite plan.
  /// The `orderBy` claim is sound because the prefix is pinned by equality:
  /// within it, composite key order IS next-column order.
  func planComposite(c : Entity.ServedComposite, cs : [Predicate.Predicate], q : Query.Query)
    : ?{ rows : Iter.Iter<Row>; ordered : Bool; pushed : Bool } {
    var bare : ?{ rows : Iter.Iter<Row>; ordered : Bool; pushed : Bool } = null;
    for (cols in c.decls().values()) {
      let prefix = List.empty<Value>();
      for (col in cols.values()) {
        switch (eqOn(cs, col)) { case (?v) { prefix.add(v) }; case null { break } };
      };
      let k = prefix.size();
      if (k == cols.size() and k > 0) {
        return ?{ rows = c.range(cols, prefix.toArray(), null, null, #asc); ordered = false; pushed = true };
      };
      if (k > 0) {
        let next = cols[k];
        let (lo, hi) = boundsFor(cs, next);
        let ob = q.aggregate.size() == 0 and q.groupBy.size() == 0
          and q.orderBy.size() == 1 and q.orderBy[0].field.size() == 1 and q.orderBy[0].field[0] == next;
        if (ob) {
          return ?{ rows = c.range(cols, prefix.toArray(), lo, hi, q.orderBy[0].dir); ordered = true; pushed = true };
        };
        if (lo != null or hi != null or k > 1) {
          return ?{ rows = c.range(cols, prefix.toArray(), lo, hi, #asc); ordered = false; pushed = true };
        };
        switch bare {
          case null { bare := ?{ rows = c.range(cols, prefix.toArray(), null, null, #asc); ordered = false; pushed = false } };
          case _ {};
        };
      };
    };
    bare
  };

  /// The first `#eq` on exactly the single-segment column `col`.
  func eqOn(cs : [Predicate.Predicate], col : Text) : ?Value {
    for (p in cs.values()) {
      switch p { case (#eq(path, v)) { if (path.size() == 1 and path[0] == col) return ?v }; case _ {} };
    };
    null
  };

  /// Flatten a where clause's top-level conjunction into its leaf predicates —
  /// the sargable candidates a plan may drive on. Only `#and_` is transparent: a
  /// leaf under `#or_`/`#not_` is not a superset of the query's matches, so it
  /// never surfaces here. Computed once per plan; the finders below scan the
  /// flat list rather than each re-walking the tree.
  func conjuncts(where_ : ?Predicate.Predicate) : [Predicate.Predicate] {
    let acc = List.empty<Predicate.Predicate>();
    func go(p : Predicate.Predicate) = switch p {
      case (#and_ ps) { for (x in ps.values()) { go(x) } };
      case _          { acc.add(p) };
    };
    switch where_ { case (?p) { go(p) }; case null {} };
    acc.toArray()
  };

  /// Join-aware plan: an edge-path filter `edge.col <op> v` (a constraint on a
  /// column of the *target* entity, where `<op>` is `=`/`in`/a range) becomes a
  /// semi-join. Resolve the target rows the constraint admits, take their primary
  /// keys, and drive the start through an `#in_` on the foreign-key column's
  /// index — reusing `s.points`. So a filter behind an edge is served by the FK
  /// index instead of scanning every start row.
  ///
  /// Requires the FK column (`edge`) to be a served index on the start and a
  /// declared edge. The target's matches come from its own index when the
  /// constraint is an `#eq` on a served target column (a point probe), else a
  /// scan of the target — cheap for the usual dimension table. Complete for these
  /// positive filters: a start row with a dangling FK has `edge.col = null`,
  /// which none of them admit, so dropping it is correct. A denied target admits
  /// nothing (empty `#in_`), matching the left-join-to-null the residual produces.
  /// When `requireCost` is true, the target predicate must be served by a point
  /// index; otherwise this returns `null` and preserves the direct source.
  func planJoin(
    hops : Hops,
    r : Registry.Registry,
    start : Entity.Decl,
    s : Entity.Served,
    _q : Query.Query,
    access : Access,
    cs : [Predicate.Predicate],
    requireCost : Bool,
    candidateLimit : Nat,
  ) : ?JoinPlan {
    switch (findEdgeFilter(cs, s, start)) {
      case null { null };
      case (?(edge, targetPred, ci)) {
        // The `#in_` on `edge` is EXACT for this conjunct (a start row's FK is in
        // `pks` iff its target satisfies `targetPred`, and dangling/denied FKs
        // are excluded either way), so the conjunct drops out of the residual —
        // which is what lets the dimension index stay unbuilt when nothing else
        // traverses into the target.
        let residual = reassembleExcept(cs, ci);
        let ?targetName = edgeTarget(start, edge) else return null;
        let ?target = Registry.lookup(r, targetName) else return null;
        let tSubject = switch (access(target)) {
          case (#deny) {
            return ?{
              rows = s.points(edge, []);
              ordered = false;
              residual;
              candidates = ?#exact(0);
            }
          };  // can't read target → no matches
          case (a)     { subjectOf(a) };
        };
        // Primary keys of the targets the (rewritten) constraint admits.
        let pks = List.empty<Value>();
        func admit(trow : Row) {
          if (Predicate.eval(targetPred, trow)) {
            switch (trow.get([target.primaryKey])) { case (?pk) { pks.add(pk) }; case null {} };
          };
        };
        // Fast path: an `#eq` on a column the TARGET itself indexes → probe that
        // index, WITHOUT materialising the whole dimension (this is what keeps a
        // semi-join's cost proportional to its matches). Resolved as an explicit
        // option rather than a pattern with a condition attached: Motoko has no
        // `case` guards, so `case pat if cond {…}` matches `pat` and then does
        // nothing when `cond` is false instead of trying the later arms — which
        // would leave `pks` empty and turn a shape that merely misses the fast
        // path (an `#eq` on an UNindexed target column) into an empty result.
        let pointRows : ?Iter.Iter<Row> = switch (tSubject, target.served, targetPred) {
          case (null, ?ts, #eq(path, v)) {
            if (path.size() == 1 and ts.kindOf(path[0]) != null) ?ts.point(path[0], v) else null;
          };
          case _ null;
        };
        if (requireCost) {
          switch pointRows { case null { return null }; case _ {} };
        };
        switch pointRows {
          case (?it) { for (trow in it) { admit(trow) } };
          // Otherwise build (once, via `getIndex`) and reuse the target's PK
          // index — the key IS the primary key. Fall back to a fresh scan only if
          // the target has no recipe (the edge filter is always a queried path,
          // so it normally does).
          case null {
            switch (getIndex(hops, targetName)) {
              case (?idx) { for ((pk, trow) in idx.entries()) { if (Predicate.eval(targetPred, trow)) { pks.add(pk) } } };
              case null { for (trow in target.rows(tSubject)) { admit(trow) } };
            };
          };
        };
        let keys = pks.toArray();
        let candidates = if (requireCost) pointsCountForPlan(s, edge, keys, candidateLimit) else null;
        if (requireCost) {
          switch candidates { case null { return null }; case _ {} };
        };
        // `s.points` matches start rows whose FK is in `pks` via the index's
        // numeric-bridging compare, but `wrapRow` (the scan/residual path)
        // left-joins a #float (or null) FK to null — so an integral #float FK
        // like 3.0 is admitted by the index yet excluded on a scan. Because we
        // DROP the edge conjunct from the residual, replicate wrapRow's guard
        // here: keep only rows whose own FK value is joinable, making this plan
        // exact rather than a superset.
        let matched = s.points(edge, keys).filter(func (row : Row) : Bool =
          switch (row.get([edge])) { case (?fk) { joinableValue(fk) }; case null { false } });
        ?{ rows = matched; ordered = false; residual; candidates }
      };
    };
  };

  /// Size of a union of point probes, stopping as soon as its proven lower
  /// bound means it cannot beat the competing source. `points` de-duplicates
  /// numerically equivalent keys, so mirror that here.
  func pointsCountForPlan(
    s : Entity.Served,
    col : Text,
    keys : [Value],
    limit : Nat,
  ) : ?Entity.CountEstimate {
    let ?st = s.stats else return null;
    let seen = Map.empty<Value, ()>();
    var total = 0;
    for (key in keys.values()) {
      if (seen.get(Predicate.compare, key) == null) {
        seen.add(Predicate.compare, key, ());
        let remaining = limit - total;
        switch (st.countUpTo(col, key, remaining)) {
          case (?(#exact n)) {
            if (n > remaining) return ?#atLeast(total + n);
            total += n;
          };
          case (?(#atLeast n)) return ?#atLeast(total + n);
          case null { return null };
        };
      };
    };
    ?#exact(total)
  };

  /// `cs` reassembled into one predicate with the conjunct at `skip` removed —
  /// the residual after a plan has EXACTLY served that conjunct. Conjunction is
  /// associative, so this equals the original `where_` minus that leaf; `null`
  /// when nothing remains.
  func reassembleExcept(cs : [Predicate.Predicate], skip : Nat) : ?Predicate.Predicate {
    let rest = List.empty<Predicate.Predicate>();
    var i = 0;
    for (p in cs.values()) { if (i != skip) rest.add(p); i += 1 };
    let arr = rest.toArray();
    if (arr.size() == 0) { null } else if (arr.size() == 1) { ?arr[0] } else { ?(#and_ arr) };
  };

  /// The target entity of a declared `#edge` field `name` on `start`, if any.
  func edgeTarget(start : Entity.Decl, name : Text) : ?Text {
    for (f in start.fields.values()) {
      if (f.name == name) { return (switch (f.role) { case (#edge e) { ?e.to }; case _ { null } }) };
    };
    null
  };

  /// The first `edge.col <op> v` (two-segment path, `<op>` ∈ `=`/`in`/range)
  /// through top-level `#and_` whose head is both a served index and a declared
  /// edge of `start`. Returns the FK column and the constraint rewritten onto the
  /// target column (path `[col]`) so it can be `Predicate.eval`'d on target rows.
  func findEdgeFilter(cs : [Predicate.Predicate], s : Entity.Served, start : Entity.Decl)
    : ?(Text, Predicate.Predicate, Nat) {
    // (edge, col) when `path` is a two-segment `edge.col` on a served FK edge.
    func split(path : Types.Path) : ?(Text, Text) =
      if (path.size() == 2 and s.kindOf(path[0]) != null and edgeTarget(start, path[0]) != null)
        ?(path[0], path[1]) else null;
    var i = 0;
    for (p in cs.values()) {
      let m : ?(Text, Predicate.Predicate) = switch p {
        case (#eq(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #eq([c], v)) };  case null { null } } };
        case (#in_(path, v)) { switch (split(path)) { case (?(e, c)) { ?(e, #in_([c], v)) }; case null { null } } };
        case (#lt(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #lt([c], v)) };  case null { null } } };
        case (#le(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #le([c], v)) };  case null { null } } };
        case (#gt(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #gt([c], v)) };  case null { null } } };
        case (#ge(path, v))  { switch (split(path)) { case (?(e, c)) { ?(e, #ge([c], v)) };  case null { null } } };
        case _ { null };
      };
      switch m { case (?(e, pr)) { return ?(e, pr, i) }; case null {} };
      i += 1;
    };
    null
  };

  /// The first `#eq` on an indexed single-segment column.
  func findEq(cs : [Predicate.Predicate], s : Entity.Served) : ?(Text, Value) {
    for (p in cs.values()) {
      switch p { case (#eq(path, v)) { if (path.size() == 1 and s.kindOf(path[0]) != null) return ?(path[0], v) }; case _ {} };
    };
    null
  };

  /// The first `#in_` on an indexed single-segment column.
  func findIn(cs : [Predicate.Predicate], s : Entity.Served) : ?(Text, [Value]) {
    for (p in cs.values()) {
      switch p { case (#in_(path, vs)) { if (path.size() == 1 and s.kindOf(path[0]) != null) return ?(path[0], vs) }; case _ {} };
    };
    null
  };

  /// The first indexed single-segment column carrying a range bound.
  func findRangeCol(cs : [Predicate.Predicate], s : Entity.Served) : ?Text {
    for (p in cs.values()) {
      switch p {
        case (#lt(path, _) or #le(path, _) or #gt(path, _) or #ge(path, _)) {
          if (path.size() == 1 and s.kindOf(path[0]) != null) return ?path[0];
        };
        case _ {};
      };
    };
    null
  };

  /// Inclusive `[lo, hi]` bounds for `col` gathered from the conjuncts
  /// (`#gt`/`#ge` → `lo`, `#lt`/`#le` → `hi`; strictness is left to the residual
  /// filter). A missing bound stays open; looser bounds only widen the superset,
  /// never drop a match.
  func boundsFor(cs : [Predicate.Predicate], col : Text) : (?Value, ?Value) {
    var lo : ?Value = null;
    var hi : ?Value = null;
    for (p in cs.values()) {
      switch p {
        case (#gt(path, v) or #ge(path, v)) { if (path.size() == 1 and path[0] == col and lo == null) lo := ?v };
        case (#lt(path, v) or #le(path, v)) { if (path.size() == 1 and path[0] == col and hi == null) hi := ?v };
        case _ {};
      };
    };
    (lo, hi)
  };

  // ── Edge traversal ──────────────────────────────────────────────────────

  /// How to build a target's PK index, resolved at `collectHops` time but not
  /// executed until the first traversal into that target (see `getIndex`).
  type Recipe = { #deny; #build : (Entity.Decl, ?Principal) };

  /// Validated hops + lazily-built per-target PK indexes for one query.
  type Hops = {
    edges   : Map.Map<Text, Text>;                 // "<entity>\u{1f}<edge>" -> target entity
    recipes : Map.Map<Text, Recipe>;               // target entity -> how to build its PK index
    cache   : Map.Map<Text, Map.Map<Value, Row>>;  // PK index, built on first traversal into the target
  };

  /// Collect every dotted path in the query, validate each hop against the
  /// schema, and record — per distinct target entity — how to build its PK
  /// index (its resolved access): a denied target yields an empty index (every
  /// traversal into it is a left-join null), a scoped target only its
  /// caller-owned rows. The index itself is built lazily on first traversal
  /// (see `getIndex`), so a target that is never traversed is never scanned.
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
        edges.add(Text.compare, entity.name # "\u{1f}" # path[i], target.name);
        if (seen.get(Text.compare, target.name) == null) {
          seen.add(Text.compare, target.name, ());
          needed.add(target);
        };
        entity := target;
        i += 1;
      };
    };

    // Resolve access per target now (so the recipe captures the right subject),
    // but DEFER the row scan: the index is built on first traversal, so a query
    // that never traverses into a target (e.g. a semi-join the FK plan already
    // satisfies) never materialises that dimension.
    let recipes = Map.empty<Text, Recipe>();
    for (decl in needed.values()) {
      let recipe : Recipe = switch (access(decl)) {
        case (#deny) { #deny };                          // denied target -> left-join null
        case (a)     { #build(decl, subjectOf(a)) };
      };
      recipes.add(Text.compare, decl.name, recipe);
    };
    { edges; recipes; cache = Map.empty<Text, Map.Map<Value, Row>>() }
  };

  /// A target's PK index, built on first access and cached. This is what makes a
  /// dimension scan pay-per-use: a join only materialises a target when a query
  /// actually traverses into it (a projection, a group key, or a residual edge
  /// predicate). A denied target resolves to an empty index (every traversal a
  /// left-join null); an unknown target (no recipe) yields null.
  func getIndex(hops : Hops, name : Text) : ?Map.Map<Value, Row> {
    switch (hops.cache.get(Text.compare, name)) {
      case (?idx) { ?idx };
      case null {
        switch (hops.recipes.get(Text.compare, name)) {
          case (?#build(decl, subject)) { let idx = buildIndex(decl, subject); hops.cache.add(Text.compare, name, idx); ?idx };
          case (?#deny) { let idx = Map.empty<Value, Row>(); hops.cache.add(Text.compare, name, idx); ?idx };
          case null { null };
        };
      };
    };
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
    let ?fld = entity.fields.find(func f = f.name == edge) else Runtime.trap("OQL: '" # edge # "' is not an edge of '" # entity.name # "'");
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

  /// Whether a Value may serve as a join key. The PK index is keyed on `Value`
  /// directly via `Predicate.compare` (which bridges `#nat`/`#int`), so there
  /// is no per-access Text encoding; this only gates build-time insertion so a
  /// target with a null/float primary key surfaces loudly instead of silently
  /// left-joining every traversal to null.
  func joinableValue(v : Value) : Bool = switch v {
    case (#text _) true;
    case (#nat  _) true;
    case (#int  _) true;
    case (#bool _) true;
    case _ { false };
  };

  func buildIndex(decl : Entity.Decl, subject : ?Principal) : Map.Map<Value, Row> {
    let idx = Map.empty<Value, Row>();
    for (row in decl.rows(subject)) {
      let pk = row.get([decl.primaryKey]).get(#null_);
      if (not joinableValue(pk)) {
        Runtime.trap("OQL: row of '" # decl.name # "' has no joinable primary key '"
          # decl.primaryKey # "'")
      };
      idx.add(Predicate.compare, pk, row);
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
          let ?target = hops.edges.get(Text.compare, entityName # "\u{1f}" # path[0]) else return null;
          let ?idx = getIndex(hops, target) else return null;
          let ?fk = base.get([path[0]]) else return null;
          // Float/null FKs are unjoinable by design — a float PK traps at build
          // time, so mirror that on the FK side: left-join to null instead of
          // letting Predicate.compare bridge a #float FK into a numerically-equal
          // #nat/#int PK (e.g. #float 3.0 joining #nat 3, or -0.0 joining 0).
          // (A declared-Float FK is rejected earlier by validateHop's `joinable`
          // type check; this guard covers the runtime divergence case where the
          // seed row was Nat but a later row emits #float for the same FK.)
          if (not joinableValue(fk)) return null;
          switch (idx.get(Predicate.compare, fk)) {
            case null { null };               // dangling FK -> left-join null
            case (?t) {
              let rest = path.sliceToArray(1, path.size());
              if (rest.size() == 1) { t.get(rest) }          // single-hop: read off target, no re-wrap
              else { wrapRow(t, target, hops).get(rest) };   // multi-hop: keep recursion
            };
          };
        };
      };
    };
    // Own-field single-segment reads hit `base` first and are identical to
    // the base row, so forward its flat accessor; edge paths (multi-segment)
    // go through `get` above, which the flat path never serves.
    slot = base.slot; values = base.values;
  };

  /// Filter the row iterator by the predicate. `cap` bounds how many survivors
  /// to collect (lazy: the scan stops once `cap` is reached); `null` collects
  /// all. Bounding is only passed when ordering/aggregation are absent, where
  /// scan order is the result order.
  func filter(it : Iter.Iter<Row>, where_ : ?Predicate.Predicate, admit : ?(Row -> Bool), cap : ?Nat) : [Row] {
    let residual = switch where_ {
      case null    { it };
      case (?p)    { it.filter(func row = Predicate.eval(p, row)) };
    };
    // Ownership guard for a planned/pruned scoped read — applied on the LAZY
    // stream, after the residual (so app `canSee` code runs only on residual
    // survivors) and before the cap (so offset/limit/hasMore count only
    // admitted rows and cannot leak cross-owner cardinality).
    let matched = switch admit {
      case null    { residual };
      case (?g)    { residual.filter(g) };
    };
    switch cap {
      case null { matched.toArray() };
      case (?n) {
        let acc = List.empty<Row>();
        for (row in matched) {
          if (acc.size() >= n) break;
          acc.add(row);
        };
        acc.toArray()
      };
    };
  };

  /// Resolve each single-segment field to its flat slot ONCE, using a sample
  /// row's fast accessor (the slot map is shared across the entity's rows).
  /// Multi-segment paths (edge traversal) and non-flat rows yield `null`, so
  /// the per-row caller falls back to `get`.
  func resolveSlots(sample : ?Row, fields : [Path]) : [?Nat] =
    switch (do ? { sample!.slot! }) {
      case (?resolve) { fields.map<Path, ?Nat>(func p = if (p.size() == 1) resolve(p[0]) else null) };
      case null       { Array.tabulate<?Nat>(fields.size(), func _ = null) };
    };

  func project(row : Row, paths : [Path], names : [Text], slots : [?Nat]) : [Cell] =
    Array.tabulate<Cell>(paths.size(), func i = {
      name  = names[i];
      value = switch (slots[i], row.slot) {
        case (?s, ?_) { row.values[s] };              // flat: index directly
        case _        { row.get(paths[i]).get(#null_) };
      };
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

  /// Decorate-sort. The naive approach calls `row.get(c.field)` inside every
  /// comparison; for a dotted path that re-traverses the join O(n log n) times.
  /// Instead, extract each row's orderBy key ONCE (n traversals), then sort the
  /// (key, row) pairs comparing the precomputed keys. `Array.sort` is stable and
  /// `compareKeys` mirrors the old comparator exactly (same `Predicate.compare`,
  /// same asc/desc, same null handling), so the result is identical.
  func sortByKeys(rows : [Row], clauses : [Query.OrderBy]) : [Row] {
    let slots = resolveSlots(
      if (rows.size() == 0) null else ?rows[0],
      clauses.map<Query.OrderBy, Path>(func c = c.field));
    func keyOf(r : Row) : [Value] =
      Array.tabulate<Value>(clauses.size(), func i =
        switch (slots[i], r.slot) {
          case (?s, ?_) { r.values[s] };
          case _        { r.get(clauses[i].field).get(#null_) };
        });
    let decorated = rows.map<Row, ([Value], Row)>(func r = (keyOf(r), r));
    let ordered = decorated.sort<([Value], Row)>(func ((ka, _), (kb, _)) = compareKeys(ka, kb, clauses));
    ordered.map<([Value], Row), Row>(func ((_, r)) = r)
  };

  /// Compare two precomputed orderBy keys (aligned to `clauses`), applying each
  /// clause's direction. Same semantics as the former per-row comparator.
  func compareKeys(ka : [Value], kb : [Value], clauses : [Query.OrderBy]) : Order.Order {
    var i = 0;
    while (i < clauses.size()) {
      let raw = Predicate.compare(ka[i], kb[i]);
      let oriented = switch (clauses[i].dir) { case (#asc) raw; case (#desc) flip(raw) };
      if (oriented != #equal) return oriented;
      i += 1;
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
      let aggCells = aggs.map<Agg, (Text, Value)>(func a = (aggName(a), computeAgg(a, members)));
      rowOf(keyCells.concat(aggCells))
    };

    if (groupBy.size() == 0) return { rows = [aggRow([], rows)]; columns };

    let groups = Map.empty<Text, Group>();
    let order  = List.empty<Text>();
    for (row in rows.values()) {
      let keyVals = groupBy.map(func (p : Path) : Value = row.get(p).get(#null_));
      let key = groupKey(keyVals);
      switch (groups.get(Text.compare, key)) {
        case (?g) { g.members.add(row) };
        case null {
          let keyCells = Array.tabulate<(Text, Value)>(
            groupBy.size(),
            func i = (Types.pathToText(groupBy[i]), keyVals[i]),
          );
          let g : Group = { keyCells; members = List.empty<Row>() };
          g.members.add(row);
          groups.add(Text.compare, key, g);
          order.add(key);
        };
      };
    };

    let out = List.empty<Row>();
    for (key in order.values()) {
      let ?g = groups.get(Text.compare, key) else Runtime.trap("OQL: group vanished");
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
    for ((k, v) in cells.values()) m.add(Text.compare, k, v);
    {
      get = func (p : Path) : ?Value = if (p.size() == 0) null else m.get(Text.compare, Types.pathToText(p));
      slot = null; values = [];  // aggregated row is Map-backed (dotted group keys) — no flat layout.
    }
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
    case (#bool b)  { "1:" # b.toText() };
    case (#nat n)   { "2:" # n.toText() };
    case (#int i)   { "3:" # i.toText() };
    case (#float f) { "4:" # f.toText() };
    case (#text t)  { "5:" # t };
  };

};
