---
name: extension-oql
description: Make a canister's data queryable by the Caffeine Data Intelligence agent. Use whenever an app stores structured data (Maps/Lists/arrays of records) that should be answerable in natural language — "top customers", "revenue by region", "active projects". Adds a discoverable `schema()` and a JSON `execute()` query endpoint via the `caffeineai-oql` mops package's `Expose` mixin.
version: 0.1.0
compatibility:
  mops:
    caffeineai-oql: "~0.1.0"
caffeineai-subscription: [none]
---

# OQL — Object Query Layer

Author-side recipe for exposing a canister's data to OQL queries. The
consumer side (forming and running queries) is handled by the Data
Intelligence agent — your job is to declare entities over the data the app
already keeps and install the mixin.

`include Expose({ ... })` adds two read-only `shared query` methods to the
actor:

- **`schema(token : ?Text) : Text`** — a JSON catalogue of entities, their
  fields, primary keys, and edges. The discovery endpoint.
- **`execute(qJson : Text, token : ?Text) : Result`** — runs a JSON query
  (filter / order / paginate / project, aggregation, and dotted-path edge
  traversal) and returns typed Candid rows. The query endpoint.

Plus two controller-only update calls, `oqlMintToken` / `oqlRevokeToken`
(bearer credentials, see Auth). Together these replace the
"one `shared query` per question" pattern (`getCustomersInGermany()`,
`getOrdersForCustomer(id)`, …) with a single generic surface the client
drives dynamically.

You declare *entities* — query views over collections you already store. No
storage restructuring, no per-question getters.

# Backend

## Setup

Run `mops add caffeineai-oql@0.1.0` in the **same write batch** as the first
`mo:caffeineai-oql/...` import. The generated-app template already pins
`moc 1.9.0` and sets the required `--default-persistent-actors
--implicit-package=core` flags, so you do **not** configure the toolchain.
(`moc 1.9.0` is required: auto-derivation uses the `__record` structural
combiner that landed there.)

## Mixin install

Each `.toEntity(name, typeName, primaryKey)` turns a collection of records
into a queryable entity; the compiler auto-derives the fields. `Expose` adds
exactly the four methods above — existing `shared` methods, state, and types
are untouched.

```motoko filepath=src/backend/main.mo
import Map    "mo:core/Map";
import Nat    "mo:core/Nat";
import OQL    "mo:caffeineai-oql";
import Expose "mo:caffeineai-oql/Expose";

actor {

  type Customer = { id : Nat; name : Text; country : Text; monthlyRevenueUsd : Nat };
  type Order    = { id : Nat; customerId : Nat; amountUsd : Nat; paid : Bool };

  let customers = Map.empty<Nat, Customer>();
  let orders    = Map.empty<Nat, Order>();

  include Expose({
    entities = [
      customers.toEntity("customer", "Customer", "id")
        .sample({ id = 0; name = ""; country = ""; monthlyRevenueUsd = 0 })
        .build(),

      orders.toEntity("order", "Order", "id")
        .sample({ id = 0; customerId = 0; amountUsd = 0; paid = false })
        // `customerId` points at the customer entity's primary key:
        .edge("customerId", "customer")
        .build(),
    ];
    // Access is decided by three functions. controllerOnly lets the platform
    // (a controller) read every row; everyone else is denied. isPublic stays
    // false so the data is not world-readable, and there is no token scheme.
    isPublic       = func () : Bool = false;
    authorizeUser  = OQL.Auth.controllerOnly;
    authorizeToken = OQL.Auth.noExternalTokens;
  });

  public shared func addCustomer(c : Customer) : async () { customers.add(c.id, c) };
  public shared func addOrder(o : Order)       : async () { orders.add(o.id, o) };
};
```

## Auth

Three mandatory config functions. Each resolves an `Access` decision rather
than a bare bool:

```mo
public type Access = { #deny; #unrestricted; #scoped : Principal };
```

`#deny` does not authorize; `#unrestricted` reads every row; `#scoped p`
reads, but `#owner`-tagged entities yield only rows owned by `p` (see
*Per-user scoping* below). A read is allowed when **any** check returns a
non-`#deny` Access; the first non-deny in this order wins and its scope
threads into the executor:

```text
isPublic()                 -- the whole surface is open (#unrestricted)
authorizeUser(caller)      -- principal-based policy
<minted token>             -- bearer token from oqlMintToken; its owner is the scope
authorizeToken(token)      -- your own token scheme
```

| Config field | Shape | Presets in `OQL.Auth` |
|---|---|---|
| `isPublic` | `() -> Bool` | write the literal (`func () : Bool = false`) |
| `authorizeUser` | `Principal -> Access` | `controllerOnly` (→ `#unrestricted`), `selfScoped` (→ `#scoped caller`), `noUsers` |
| `authorizeToken` | `Text -> Access` | `noExternalTokens` |

The check runs at the top of **both** `schema()` and `execute()`. A denied
caller traps.

**Default to controller-only.** Set `isPublic = func () : Bool = false`,
`authorizeUser = OQL.Auth.controllerOnly`, `authorizeToken =
OQL.Auth.noExternalTokens`. The Data Intelligence agent reads as a platform
controller, so it can answer questions while the data stays private to
non-controllers. Set `isPublic = func () : Bool = true` only for
intentionally world-readable data.

Custom policies are just plain functions returning `Access`:

```mo
let admins : Set.Set<Principal> = Set.empty();
authorizeUser = func (p : Principal) : OQL.Auth.Access =
  if (p.isController() or admins.contains(p)) #unrestricted
  else if (p.isAnonymous()) #deny
  else #scoped p;   // every other signed-in user sees only their own rows
```

**Bearer tokens.** `oqlMintToken(owner : ?Principal, ttlSeconds : ?Nat)` — a
controller-only update call — returns a 64-hex token, valid until its TTL
lapses or `oqlRevokeToken(token)` removes it. The minted-token store is
`transient` (the mixin keeps no stable field, so it stays
enhanced-migration compatible), so **tokens reset on every canister upgrade —
re-mint afterwards**. Pass `owner = ?p` to mint a token that reads only `p`'s
rows; `owner = null` mints an unrestricted token. Readers pass it as the
trailing `opt text` argument of `schema`/`execute` — no controllerhood, no
principal exchange. Tokens travel in query arguments (visible to the node
operator, replayable until revoked or expired), so mint with a TTL when
sharing externally. `authorizeToken` runs *in addition to* the minted-token
store, for authors operating their own token scheme.

### Per-user (row-level) scoping

Mark any entity per-user with one builder line — `.ownedBy(field)` — naming
the column that holds the row's owner principal. When the caller resolves to
`#scoped p`, that entity yields only rows whose owner equals `p`, both as a
query's `start` and as a join target (so dotted-path traversal can't leak
another owner's rows; dangling-under-scope FKs left-join to `null`).
`#unrestricted` callers see everything. Entities you do **not** mark stay
global (visible to any authorized caller).

The owner subject is **either the direct caller** (`authorizeUser` returning
`#scoped caller`, e.g. `selfScoped`, for apps where each end user calls with
its own principal) **or the owner bound to a token** (`oqlMintToken(?p, ...)`,
for a backend minting one token per user). Both collapse to the same subject.

When rows are stored keyed by owner (e.g. `Map<Principal, List<T>>`), use
`OQL.Entity.newScoped(name, scopedIter, typeName, primaryKey)` so the scan is
O(user rows) instead of a full-table filter; `scopedIter` receives the
subject (`null` = unrestricted, used for schema seeding — pair with
`.sample`).

**Override the scheme with your own predicate.** `.ownedBy(field)` uses
principal equality. For app-specific authorization use `.ownedByWith(field,
canSee)` where `canSee : (Principal, OQL.Value) -> Bool` receives the resolved
caller subject and the row's owner-cell value and returns true to expose the
row. Capture actor state in the closure; the owner column need not be a
principal.

```mo
// `allowedUsers : Map<Principal, ()>` is your own actor state.
docs.toEntity("doc", "Doc", "id")
  .ownedByWith("owner", func (caller, owner) =
    allowedUsers.get(caller) != null            // listed → see everything
    or owner == #text(caller.toText()))         // otherwise → only your own
  .build()
```

The column is still tagged role `"owner"` in `schema()`, join-target scoping
still applies, and `#unrestricted` callers still bypass the check.
(`.ownedBy(field)` is exactly `.ownedByWith(field, OQL.Entity.ownerIsCaller)`.)

## Entity builder

OQL ships two builder modes, picked by what the row type `T` looks like.

### Auto-derivation (`.toEntity`)

For plain records whose fields are all primitives with a `_toRow` instance
(`Nat`, `Int`, `Float`, `Text`, `Bool`, the sized widths `Nat8/16/32/64` and
`Int8/16/32/64`, and `Principal`), the compiler walks the record type and
synthesises the payload schema.

```mo
customers.toEntity(name, typeName, primaryKey)
  .sample(template)                        // optional, see below
  .edge(fieldName, targetEntity)           // re-tag an auto-derived field as FK
  .ownedBy(fieldName)                      // owner column → per-user scoping
  .ownedByWith(fieldName, canSee)          // ...with an app-defined predicate
  .domain(fieldName, [values])             // declare a field's allowed values
  .hidden(fieldName)                       // drop a field from the schema
  .build()
```

- `customers.toEntity(...)` is contextual-dot sugar for
  `OQL.Entity.new<Customer>(name, func () = customers.values(), typeName,
  primaryKey)`. The same `.toEntity` exists on `Map`, `Set`, `List`, `[T]`,
  and `[var T]`.
- `.edge(name, target)` does NOT add a field — it tags an already-derived
  field as a foreign key into `target`. The field must exist on the record.
  The tag is what **enables server-side traversal**: queries can then
  filter/group/sort/project on `"<name>.<targetField>"` dotted paths. An
  undeclared FK stays a plain scalar, and dotted paths into it trap.
  Joinability: the target's primary key must not be `.hidden`, and FK/PK
  types must be `Text`, `Nat`/`Int` (bridged), or `Bool` — `Float` keys are
  rejected at query time.
- `.domain(name, values)` declares the distinct values a field can hold (e.g.
  the text arms of a variant). They surface in `schema()` as the field's
  `values` array so clients filter with exact literals. `values` is a
  `[OQL.Value]`, e.g. `[#text("draft"), #text("published")]`.
- `.ownedBy(name)` / `.ownedByWith(name, canSee)` — owner column → per-user
  scoping (see Auth). At most one owner column; it must be a real
  declared/derived field and may not also be `.edge` or `.hidden`.
- `.hidden(name)` drops a derived field from `schema()` and the default
  projection. `select` cannot bring it back.
- `.sample(template)` is the schema-discovery seed. **Required when the
  underlying collection may be empty at `build()` time** — otherwise the
  schema materialises as `[]` and stays empty until the first row arrives.
  Pass any well-typed instance of `T`; only the shape matters.

The auto-derived schema lists fields in **lexicographic order** — the
canonical form the `__record` combiner produces. If display order matters,
sort client-side or pass an explicit `select`.

### Manual mode (`.toEntityManual` / `OQL.Entity.manual`)

For non-record `T`, records with nested fields / variants / options /
collections, or any computed field, use the manual escape hatch.

```mo
articles.toEntityManual<Article>(name, typeName, primaryKey)
  .payload(fieldName, extract : T -> V)    // V picks a _toRow instance
  .flatten(extract : T -> S)               // splice a nested record's fields in
  .domain (fieldName, [values])            // declare a field's allowed values
  .edge   (fieldName, targetEntity)        // tags a declared payload as FK
  .hidden (fieldName)                      // drops a declared payload
  .build()
```

- `.payload(name, extract)` adds one field. `extract` returns any `V` whose
  `_toRow` instance is in scope. For options and variants, write a tiny local
  helper returning `Text` or `Nat` with a sentinel for absence. The name must
  not contain `.` — dots are the edge-traversal separator.
- `.flatten(extract)` splices a **nested record** in as flat, top-level
  columns — one line instead of one `.payload` per inner field. `extract : T
  -> S` returns the sub-record; the combiner walks `S` and every field becomes
  its own column under its (unprefixed) name. `S` must be flat. Drop unwanted
  fields with `.hidden(name)` afterwards.
- `.edge` / `.hidden` tag and drop already-declared fields by name; the name
  must match a `.payload` (or a field a `.flatten` produced).
- For row sources that aren't a container shortcut (a custom flattener, a
  filtered iterator), call `OQL.Entity.manual<T>(name, iter, typeName,
  primaryKey)` directly.

```mo
// Author = { id : Nat; name : Text; address : Address; tags : [Text] }
// Address = { city : Text; country : Text; postalCode : Text }
authors.toEntityManual<Author>("author", "Author", "id")
  .payload("id",   func a = a.id)
  .payload("name", func a = a.name)
  .flatten(func a = a.address)             // → city, country, postalCode columns
  .payload("tagCount", func a = a.tags.size())
  .build()
```

**Colliding column names.** If a flattened field clashes with another column,
the first occurrence keeps the bare name and each later one gets a `__1`,
`__2`, … suffix. Both columns survive and stay queryable — nothing is
silently dropped.

`OQL.Value` is `{ #null_; #bool : Bool; #nat : Nat; #int : Int; #float :
Float; #text : Text }`. The built-in `_toRow` set covers the primitives and
`Principal` (rendered as `#text`). Numeric variants (`#nat`/`#int`/`#float`)
compare across each other in predicates, so a JSON integer threshold still
matches a `Float` row value.

#### Which mode?

| Row type `T` | Mode |
|---|---|
| Record of primitives only | auto-derive (`.toEntity`) |
| Record with `?Field` | auto-derive once you ship `Opt<T>Value.mo`, else manual |
| Record with nested record (`addr : Address`) | auto once you ship `AddressValue.mo` collapsing to its PK; else manual with `.flatten(func x = x.addr)` |
| Record with a variant field | auto once you ship `<Variant>Value.mo`, else manual with inline `f : MyVariant -> Text` |
| Record with a collection field (`[Tag]`, `Set<…>`) | manual — `.size()` or `Text.join` into a payload |
| Tuple, primitive, or anything else | manual — `T` isn't a record so the combiner doesn't apply |

## Custom `_toRow` instances (extending auto-derivation)

OQL's implicit resolver looks at modules imported in the actor's composition
root, not just the library's built-ins. Any type for which you write `_toRow
: T -> OQL.Value` becomes auto-derivable as a *field* of another record:

1. One file per type, named `<TypeName>Value.mo`.
2. A single `public func _toRow(self : T) : OQL.Value`.
3. Import the module at the **top level** of the file that declares your
   entities (not nested in a submodule — the resolver does not walk submodules).

Once in scope, parent records carrying those fields ride `.toEntity(...)`
with no manual `.payload` per field.

```mo
// DepartmentValue.mo — nested record → child's primary key
import OQL   "mo:caffeineai-oql";
import Types "Types";
module {
  public func _toRow(self : Types.Department) : OQL.Value = #text(self.name);
};
```

Every parent carrying `department : Department` now auto-derives a
`department : Text` cell holding the FK; re-tag it with `.edge("department",
"department")`.

```mo
// OptTextValue.mo — optional field → pick a sentinel
import OQL "mo:caffeineai-oql";
module {
  public func _toRow(self : ?Text) : OQL.Value = switch self {
    case null { #text("") };
    case (?t) { #text(t) };
  };
};
```

**Always commit to one `Value` variant**, even for the null case — a `_toRow`
that returns `#null_` for some rows and `#text` for others makes the schema's
reported type flip-flop based on row order. Sentinels keep the schema stable
AND keep the field queryable (`{ "eq": { "field": "x", "value": "" } }`
matches the null rows). Same shape for `?Nat` (sentinel 0), `?Bool` (false).

```mo
// StatusValue.mo — variant → per-tag text
module {
  public func _toRow(self : Status) : OQL.Value = #text(switch self {
    case (#draft)     { "draft" };
    case (#published) { "published" };
    case (#archived)  { "archived" };
  });
};
```

**Two instances for the same record coexist.** A record `T` used both as a
top-level entity *and* as a nested field needs two `_toRow` shapes: the
structural `_toRow : T -> Row` the combiner synthesises (you don't write it)
and your `_toRow : T -> Value` collapse. `Row` and `Value` are distinct types,
so the resolver picks the right one in each context. Ship one `TypeValue.mo`
and both paths work.

**When it's worth it:** if two or more entities embed the same nested record
type, write the instance — it pays for itself the second time. For one-off
embeds, an inline `.payload` extract is fine.

## The four entity patterns

The same storage can back several patterns at once. Pick whichever matches
what the client should see.

**concrete** — one row per element of an existing collection. The common case
(the `customer` entity above).

**reshaped** — flatten nested storage, promote inner keys to columns. Have the
flattener emit a flat **record** (not a tuple) so the custom row source rides
auto-derivation with no per-field `.payload`:

```mo
// metrics : Map<Int (bucket), Map<Nat (sensor), Measurement>>
type MeasurementRow = { bucket : Int; sensor : Nat; metric : Text; value : Nat; okay : Bool };

OQL.Entity.new<MeasurementRow>(
  "measurement", func () = flattenMetrics(metrics), "MeasurementRow", "sensor",
)
  .edge("bucket", "bucket")
  .edge("sensor", "sensor")
  .build()
```

A tuple `(Int, Nat, Measurement)` has no field names, so it can't
auto-derive — emit a flat record instead.

**enumerated** — derive an entity from an existing index, no dedicated
storage. Use when entities live inside other records and you have a
`Map<Entity, _>` keyed by them:

```mo
// articlesByAuthor : Map<Author, List<Article>> already exists
OQL.Entity.manual<Author>("author", func () = articlesByAuthor.keys(), "Author", "id")
  .payload("id",   func a = a.id)
  .payload("name", func a = a.name)
  .flatten(func a = a.address)
  .build()
```

Trade-off: authors with no articles never appear, by construction.

**synthetic** — project rows from an array-typed field, no junction table on
disk. Makes many-to-many relationships queryable from both sides:

```mo
// Article = { id : Nat; tags : [Text]; ... }
OQL.Entity.manual<(Article, Text)>(
  "articleTag", func () = flattenArticleTags(articles), "Pair", "pair",
)
  .payload("article", func ((a, _)) = a.id)
  .edge   ("article", "article")
  .payload("tag",     func ((_, t)) = t)
  .edge   ("tag",     "tag")
  .build()
```

In manual mode `.edge(name, target)` tags a payload field as a FK — the value
still comes from the matching `.payload`, so you write both lines.

## Manual-mode helpers for options, variants, collections

When a non-primitive field is too local to be worth a per-type module (used in
exactly one entity, or a one-off computed shape), inline the conversion in the
builder. Same sentinel discipline — pick one `Value` variant and stay there.

```mo
func optText(o : ?Text) : Text = switch o { case null ""; case (?t) t };
func optNat(o : ?Nat)   : Nat  = switch o { case null 0;  case (?n) n };
func statusText(s : Status) : Text = switch s {
  case (#draft) "draft"; case (#published) "published"; case (#archived) "archived";
};
func tagSummary(tags : [Text]) : Text = Text.join(tags.values(), ",");
```

…then in the builder:

```mo
.payload("terminationDate", func e = optText(e.terminationDate))
.payload("status",          func a = statusText(a.status))
.payload("tagCount",        func a = a.tags.size())
.payload("tagSummary",      func a = tagSummary(a.tags))
```

**Rule of thumb.** If the same conversion would appear in two or more
entities, lift it to a `<TypeName>Value.mo` module and let auto-derive wire
it. If it's strictly local, the inline helper is shorter.

## What OQL does NOT do

- **No reverse joins (fan-out).** Forward, single-valued edges ARE traversable
  server-side with dotted paths (`"customerId.country"`); one-to-many needs a
  second `execute()` with `in`.
- **No writes.** `execute` is `shared query`. Mutations stay in your own
  `shared` methods.
- **No query planner.** Each `execute` is a linear scan over the row source.
  For fast point lookups, build a `Map` and have the row source walk it.
- **No nested-record paths.** Dotted paths cross *edges* (max 4 hops); nested
  records flatten to top-level columns at declaration time (`.flatten`).
- **No built-in `_toRow` for Option, Variant, nested records, collections.**
  Ship a `<TypeName>Value.mo` for the first three to stay on auto-derive, or
  drop to manual mode.
- **Per-user scoping is opt-in per entity.** Unmarked entities are visible to
  any authorized caller.

## Cost model

Every `execute` is one `shared query` call: the row source iterates once, each
row materialises into extracted cells, the predicate runs per row, survivors
are collected (and sorted `O(n log n)` if `orderBy` is set), then `offset` +
`limit` slice and the projection materialises. No caching, no planner — work
is proportional to the row source's length. If a query must be bounded, make
the row source bounded (walk an index, not a full table).

## Checklist: adding an entity

- [ ] Storage iterator exists (`func () = collection.values()`) or flattener written
- [ ] Mode chosen: all-primitive fields → `.toEntity`; custom `_toRow` instances in scope → still auto; tuples/collections/computed → `.toEntityManual` / `OQL.Entity.manual`
- [ ] For every non-primitive field type used by 2+ entities, a `<TypeName>Value.mo` exists and is imported at the top of the composition root
- [ ] Auto mode: `.sample(template)` declared (required if the collection may be empty at build time)
- [ ] Manual mode: every exposed field has a `.payload`, or a nested record is spliced with `.flatten(func x = x.sub)`
- [ ] FK fields tagged with `.edge(name, targetEntity)`
- [ ] Filter-only fields use `.hidden(name)`
- [ ] All sentinel conversions return ONE `Value` variant (never `#null_` mixed with `#text`)
- [ ] Per-user entities marked with `.ownedBy(field)` / `.ownedByWith(field, canSee)`
- [ ] `.build()` at the end, entity added to the `entities = [...]` array
- [ ] Don't hand-write `schema` / `execute` — the mixin provides them
- [ ] Compiles (`mops build` / deploy)
