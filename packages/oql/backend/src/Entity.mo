/// Entity declarations: the type-parametric builder users compose with,
/// and the type-erased `Decl` the registry stores.
///
/// `new` auto-derives the payload schema from `T` via the compiler's
/// `__record` combiner (motoko#5903) + per-primitive `_toRow` instances.
/// `manual` is the escape hatch for non-record `T`, nested records,
/// variants, collections, or computed fields.

import Iter      "mo:core/Iter";
import List      "mo:core/List";
import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Principal "mo:core/Principal";
import Runtime   "mo:core/Runtime";
import Text      "mo:core/Text";
import Auth      "Auth";
import Predicate "Predicate";
import Schema    "Schema";
import Types     "Types";

module {

  type Value     = Types.Value;
  type Path      = Types.Path;
  type Role      = Types.FieldRole;
  type TableAuth = Auth.TableAuth;

  /// What the derived `_toRow` wrapper produces: one entry per record
  /// field, in lexicographic order (Motoko's canonical record form).
  public type Row = [(Text, Value)];

  /// How an `#owner`-scoped entity decides, for a scoped caller, whether a
  /// row is visible. `field` is the owner column; `canSee(subject, owner)`
  /// receives the resolved caller subject and that row's owner-cell value
  /// and returns true to keep the row. The default scheme is principal
  /// equality (`OwnerCheck` = the caller owns rows whose column equals its
  /// own principal); apps override it to implement teams, roles, delegated
  /// access, derived account ids, and so on.
  public type OwnerCheck = (subject : Principal, owner : Value) -> Bool;

  type OwnerSpec = { field : Text; canSee : OwnerCheck };

  /// Default `.ownedBy` scheme: a caller sees rows whose owner column is
  /// exactly its own principal (rendered as `#text`).
  public func ownerIsCaller(subject : Principal, owner : Value) : Bool =
    owner == #text(Principal.toText(subject));

  /// Mid-construction builder. `build()` erases `T`.
  ///
  /// `source` is the row source, parameterised by the resolved query
  /// subject: `null` is an unrestricted read (every row), `?p` is a read
  /// scoped to principal `p`. Non-scoped sources (`new`/`manual`/the
  /// container shortcuts) ignore the argument; `newScoped` honours it.
  ///
  /// `auth` is the entity's authorization level (default `#controllerOnly`);
  /// `scopedSource` records whether `source` honours the subject argument
  /// (only `newScoped`), which — together with an owner column — is what
  /// makes a scoped level safe to expose.
  public type Builder<T> = {
    name         : Text;
    typeName     : Text;
    source       : ?Principal -> Iter.Iter<T>;
    primaryKey   : Text;
    toRow        : T -> Row;
    // Each extra contributes zero-or-more cells to a row. `.payload`
    // yields a singleton; `.flatten` splices a nested record's sub-row.
    extras       : List.List<T -> Row>;
    edges        : List.List<{ name : Text; to : Text }>;
    hidden       : List.List<Text>;
    domains      : List.List<{ name : Text; values : [Value] }>;
    owner        : List.List<OwnerSpec>;  // at most one entry: the owner column + its check
    sample       : List.List<T>;     // at most one entry; List used for mutability
    auth         : List.List<TableAuth>;  // at most one entry; default applied in build()
    scopedSource : Bool;
  };

  /// Type-erased entity descriptor stored in the registry. The `rows`
  /// closure iterates the underlying collection for a given query subject
  /// (`null` = unrestricted, `?p` = scoped to `p`), producing each row as
  /// a `Predicate.Row` that knows how to look up its own fields by path.
  /// `auth` is the entity's authorization level, resolved per caller.
  public type Decl = {
    name       : Text;
    typeName   : Text;
    primaryKey : Text;
    fields     : [Schema.FieldDecl];
    rows       : ?Principal -> Iter.Iter<Predicate.Row>;
    auth       : TableAuth;
  };

  public func new<T>(
    name       : Text,
    iter       : () -> Iter.Iter<T>,
    typeName   : Text,
    primaryKey : Text,
    _toRow     : (implicit : T -> Row),
  ) : Builder<T> = {
    name; typeName; primaryKey;
    source  = func (_ : ?Principal) : Iter.Iter<T> = iter();
    toRow   = _toRow;
    extras  = List.empty();
    edges   = List.empty();
    hidden  = List.empty();
    domains = List.empty();
    owner   = List.empty();
    sample  = List.empty();
    auth    = List.empty();
    scopedSource = false;
  };

  /// Auto-derive over a subject-scoped row source. `scopedIter` receives
  /// the resolved query subject and returns just that subject's rows
  /// (`null` should yield an unrestricted view — used for schema
  /// derivation when no `.sample` is given). Use when storage is keyed by
  /// owner (e.g. `Map<Principal, List<T>>`) so the scan is O(user rows),
  /// not a full-table filter. Prefer `.ownedBy` when each row already
  /// carries an owner column.
  public func newScoped<T>(
    name       : Text,
    scopedIter : ?Principal -> Iter.Iter<T>,
    typeName   : Text,
    primaryKey : Text,
    _toRow     : (implicit : T -> Row),
  ) : Builder<T> = {
    name; typeName; primaryKey;
    source  = scopedIter;
    toRow   = _toRow;
    extras  = List.empty();
    edges   = List.empty();
    hidden  = List.empty();
    domains = List.empty();
    owner   = List.empty();
    sample  = List.empty();
    auth    = List.empty();
    scopedSource = true;
  };


  /// Opt out of auto-derivation. Start empty, then declare every field
  /// with `.payload(...)`. Use when `T` isn't a plain record of types
  /// with `_toRow` instances.
  public func manual<T>(
    name       : Text,
    iter       : () -> Iter.Iter<T>,
    typeName   : Text,
    primaryKey : Text,
  ) : Builder<T> = {
    name; typeName; primaryKey;
    source  = func (_ : ?Principal) : Iter.Iter<T> = iter();
    toRow   = func (_ : T) : Row = [];
    extras  = List.empty();
    edges   = List.empty();
    hidden  = List.empty();
    domains = List.empty();
    owner   = List.empty();
    sample  = List.empty();
    auth    = List.empty();
    scopedSource = false;
  };

  /// Seed value for schema discovery. Required when the iter may be
  /// empty at `build()` time — otherwise schema materialises as `[]`.
  public func sample<T>(self : Builder<T>, t : T) : Builder<T> {
    self.sample.clear();
    self.sample.add(t);
    self
  };

  public func payload<T, V>(
    self    : Builder<T>,
    name    : Text,
    extract : T -> V,
    _toRow  : (implicit : V -> Value),
  ) : Builder<T> {
    // Dots are the query layer's edge-traversal separator; a dotted field
    // name would be unreachable from JSON queries. Fail at declaration.
    if (name.contains(#char '.')) {
      Runtime.trap("OQL: field name '" # name # "' must not contain '.'");
    };
    self.extras.add(func (t : T) : Row = [(name, _toRow(extract(t)))]);
    self
  };

  /// Splice a nested record's fields in as flat, top-level columns.
  ///
  /// `_toRow : S -> Row` is the compiler's structural `__record` combiner
  /// for the sub-record `S`, so every field of `S` becomes its own column
  /// automatically — no per-field `.payload`. Names are spliced verbatim
  /// (unprefixed), so `func a = a.address` on `{ city; country }` yields
  /// `city` and `country` columns directly. The sub-record's field types
  /// must themselves have `_toRow` value instances (i.e. be flat).
  public func flatten<T, S>(
    self    : Builder<T>,
    extract : T -> S,
    _toRow  : (implicit : S -> Row),
  ) : Builder<T> {
    self.extras.add(func (t : T) : Row = _toRow(extract(t)));
    self
  };

  public func edge<T>(self : Builder<T>, name : Text, to : Text) : Builder<T> {
    self.edges.add({ name; to });
    self
  };

  /// Mark `field` as the row's owner column (a `Principal` rendered as
  /// `#text`). The entity becomes per-user: when the caller resolves to a
  /// scoped subject `p`, only rows whose `field` equals `p` are yielded —
  /// in the start position AND when this entity is traversed as a join
  /// target, so edges can't leak another owner's rows. An unrestricted
  /// caller (controller / public / `owner = null` token) sees every row.
  /// The field is tagged role `#owner` in `schema()`. At most one owner
  /// column per entity; it must be a declared/derived field and may not
  /// also be `.edge`/`.hidden`.
  public func ownedBy<T>(self : Builder<T>, field : Text) : Builder<T> =
    ownedByWith<T>(self, field, ownerIsCaller);

  /// Like `.ownedBy`, but with an app-defined ownership rule. `canSee` is a
  /// real predicate the canister provides: `canSee(subject, owner)`
  /// receives the resolved caller subject and the row's owner-cell value,
  /// and returns true to expose the row. This overrides the default
  /// principal-equality scheme — capture actor state in the closure to
  /// implement teams/roles ("does `subject` belong to the team in
  /// `owner`?"), delegated access, derived account ids, etc. The same
  /// `field` is tagged role `#owner` in `schema()` and the same
  /// join-target scoping applies. Unrestricted callers still bypass the
  /// check and see every row.
  public func ownedByWith<T>(self : Builder<T>, field : Text, canSee : OwnerCheck) : Builder<T> {
    self.owner.clear();
    self.owner.add({ field; canSee });
    self
  };

  /// Set the entity's authorization level. The default (when no level is
  /// set) is `#controllerOnly`. Scoped levels (`#scopedPerUser`,
  /// `#controllerOrScoped`) require either an owner column (`.ownedBy` /
  /// `.ownedByWith`) or a subject-honouring source (`newScoped`), enforced
  /// at `build()`.
  public func auth<T>(self : Builder<T>, level : TableAuth) : Builder<T> {
    self.auth.clear();
    self.auth.add(level);
    self
  };

  /// Everyone (anonymous included) reads every row.
  public func public_<T>(self : Builder<T>) : Builder<T> = auth<T>(self, #public_);

  /// Controllers read every row; everyone else is denied.
  public func controllerOnly<T>(self : Builder<T>) : Builder<T> = auth<T>(self, #controllerOnly);

  /// Every non-anonymous caller (controllers included) is scoped to its
  /// own rows; anonymous denied.
  public func scopedPerUser<T>(self : Builder<T>) : Builder<T> = auth<T>(self, #scopedPerUser);

  /// Controllers read every row; other non-anonymous callers are scoped to
  /// their own rows; anonymous denied.
  public func controllerOrScoped<T>(self : Builder<T>) : Builder<T> = auth<T>(self, #controllerOrScoped);

  /// Declare the distinct values a field can hold (e.g. the arms of a
  /// variant rendered as text). Surfaced in `schema()` as the field's
  /// `values` array, so clients filter with exact literals instead of
  /// guessing. The name must match a declared/derived field.
  public func domain<T>(self : Builder<T>, name : Text, values : [Value]) : Builder<T> {
    self.domains.add({ name; values });
    self
  };

  /// Declare a field that appears nowhere — not in `schema()`, not in
  /// default projections, and `select` cannot bring it back.
  public func hidden<T>(self : Builder<T>, name : Text) : Builder<T> {
    self.hidden.add(name);
    self
  };

  /// Erase the row type and produce a `Decl` ready for the registry.
  /// Hidden fields are dropped here, once and for all.
  public func build<T>(self : Builder<T>) : Decl {
    let edgeLookup = Map.empty<Text, Text>();
    for (e in self.edges.values()) edgeLookup.add(e.name, e.to);

    let hiddenSet = Map.empty<Text, ()>();
    for (h in self.hidden.values()) hiddenSet.add(h, ());

    let domainLookup = Map.empty<Text, [Value]>();
    for (d in self.domains.values()) domainLookup.add(d.name, d.values);

    let ownerSpec : ?OwnerSpec = self.owner.first();
    let ownerField : ?Text = switch ownerSpec { case (?s) ?s.field; case null null };

    let level : TableAuth = switch (self.auth.first()) { case (?l) l; case null #controllerOnly };

    // A scoped level only filters when the entity can honour a subject:
    // either an owner column (`.ownedBy`/`.ownedByWith`) or a
    // subject-honouring source (`newScoped`). Without one, scoping would
    // silently never apply and every caller would see every row.
    let hasOwner : Bool = switch ownerSpec { case (?_) true; case null false };
    switch level {
      case (#scopedPerUser or #controllerOrScoped) {
        if (not hasOwner and not self.scopedSource)
          Runtime.trap("OQL: entity '" # self.name
            # "' is scoped (scopedPerUser/controllerOrScoped) but has no owner column"
            # " (.ownedBy/.ownedByWith) or subject-honouring source (newScoped)");
      };
      case _ {};
    };

    // A custom owner check paired with `#public_` would be silently
    // bypassed — every caller resolves to `#unrestricted`, so `canSee`
    // never runs. Reject the contradiction rather than leak.
    switch (ownerSpec, level) {
      case (?_, #public_) {
        Runtime.trap("OQL: entity '" # self.name
          # "' declares an owner column but is exposed #public_ — the ownership"
          # " check would never run; use a scoped level or drop .ownedBy");
      };
      case _ {};
    };

    let extras = self.extras.toArray();

    func fullRow(v : T) : Row {
      let cells = List.empty<(Text, Value)>();
      for (cell in self.toRow(v).values()) cells.add(cell);
      for (extra in extras.values()) {
        for (cell in extra(v).values()) cells.add(cell);
      };
      dedupeNames(cells)
    };

    // Schema derivation is caller-independent: prefer the explicit
    // `.sample`, otherwise take the first row of the unrestricted view.
    let seed : ?T = switch (self.sample.first()) {
      case (?s) ?s;
      case null self.source(null).next();
    };

    let schemaFields = switch seed {
      case (?v) computeFields(fullRow(v), edgeLookup, hiddenSet, domainLookup, ownerField);
      case null [];
    };

    // An owner column must actually exist and not collide with an edge or
    // a hidden field — otherwise scoping would silently never filter.
    switch ownerField {
      case (?o) {
        if (edgeLookup.get(o) != null)
          Runtime.trap("OQL: owner field '" # o # "' of '" # self.name # "' is also an edge");
        if (hiddenSet.get(o) != null)
          Runtime.trap("OQL: owner field '" # o # "' of '" # self.name # "' is hidden");
        // Existence can only be checked when a seed row materialised the
        // field list; an empty (seed-less) schema defers the check.
        let exists = schemaFields.values().any(func (f : Schema.FieldDecl) : Bool = f.name == o);
        switch seed {
          case (?_) { if (not exists) Runtime.trap("OQL: owner field '" # o # "' is not a field of '" # self.name # "'") };
          case null {};
        };
      };
      case null {};
    };

    {
      name       = self.name;
      typeName   = self.typeName;
      primaryKey = self.primaryKey;
      fields     = schemaFields;
      rows       = makeRows(self.source, fullRow, hiddenSet, ownerSpec);
      auth       = level;
    }
  };

  /// The subject-aware row closure stored on the `Decl`. Iterates the
  /// source for the resolved subject; when the entity has an owner column
  /// and the subject is a concrete principal, keeps only rows the entity's
  /// ownership check (`canSee`) admits for that subject. Unrestricted
  /// callers (`null`) and owner-less entities pass every row through.
  func makeRows<T>(
    source    : ?Principal -> Iter.Iter<T>,
    fullRow   : T -> Row,
    hiddenSet : Map.Map<Text, ()>,
    ownerSpec : ?OwnerSpec,
  ) : ?Principal -> Iter.Iter<Predicate.Row> =
    func (subject : ?Principal) : Iter.Iter<Predicate.Row> {
      let base = source(subject).map(makeRow(fullRow, hiddenSet));
      switch (ownerSpec, subject) {
        case (?spec, ?p) {
          base.filter(func (r : Predicate.Row) : Bool =
            switch (r.get([spec.field])) { case (?v) { spec.canSee(p, v) }; case null { false } })
        };
        case _ { base };
      };
    };

  /// Disambiguate repeated column names so a collision surfaces as
  /// distinct columns instead of silently overwriting. The first
  /// occurrence keeps its name; later ones get a `__1`, `__2`, … suffix.
  /// Applied inside `fullRow`, so `computeFields` (schema) and `makeRow`
  /// (per-row lookup) always agree on the final names.
  func dedupeNames(cells : List.List<(Text, Value)>) : Row {
    let seen = Map.empty<Text, Nat>();
    let out  = List.empty<(Text, Value)>();
    for ((k, v) in cells.values()) {
      let name = switch (seen.get(k)) {
        case null { seen.add(k, 0); k };
        case (?n) { let next = n + 1; seen.add(k, next); k # "__" # Nat.toText(next) };
      };
      out.add((name, v));
    };
    out.toArray()
  };

  func computeFields(
    row : Row,
    edgeLookup : Map.Map<Text, Text>,
    hiddenSet : Map.Map<Text, ()>,
    domainLookup : Map.Map<Text, [Value]>,
    ownerField : ?Text,
  ) : [Schema.FieldDecl] {
    row.filter(func ((k, _)) = hiddenSet.get(k) == null).map(
      func ((k, v)) : Schema.FieldDecl {
        let role : Role = switch (edgeLookup.get(k)) {
          case (?to) #edge({ to });
          case null  { if (ownerField == ?k) #owner else #payload };
        };
        { name = k; typeName = typeOfValue(v); role; domain = domainLookup.get(k) }
      },
    )
  };

  /// Per-row lookup table. Resolves exactly one segment; multi-segment
  /// paths are edge traversals, resolved by the executor's row wrapper —
  /// answering them here would return the FK scalar for `["edge","field"]`,
  /// a plausible-looking wrong value.
  func makeRow<T>(toRow : T -> Row, hiddenSet : Map.Map<Text, ()>) : T -> Predicate.Row =
    func (v : T) : Predicate.Row {
      let cells = Map.empty<Text, Value>();
      for ((k, val) in toRow(v).vals()) {
        if (hiddenSet.get(k) == null) cells.add(k, val);
      };
      {
        get = func (path : Path) : ?Value =
          if (path.size() != 1) null else cells.get(path[0]);
      };
    };

  /// Schema `typeName` derived from the `Value` variant. Lossy: `#nat`
  /// covers `Nat`, `Nat32`, `Nat64` alike; `#float` covers `Float`
  /// (the only IEEE-754 width Motoko exposes today).
  func typeOfValue(v : Value) : Text = switch v {
    case (#null_)   "Null";
    case (#bool  _) "Bool";
    case (#nat   _) "Nat";
    case (#int   _) "Int";
    case (#float _) "Float";
    case (#text  _) "Text";
  };

};
