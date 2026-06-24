# caffeineai-oql

Object Query Layer for Motoko canisters. Adds two read-only query methods to
an actor via the `Expose` mixin:

- `schema()` — a JSON catalogue of the canister's entities, fields, and edges.
- `execute(qJson)` — runs a JSON query (filter / order / paginate / project,
  aggregation, and dotted-path edge traversal) and returns typed Candid rows.

You declare entities over data you already keep in memory; no storage
restructuring, no per-question getters. Authorization is **per entity** — each
entity carries a level (`.public_()`, `.controllerOnly()` (default),
`.scopedPerUser()`, `.controllerOrScoped()`) resolved against the caller. See
the `extension-oql` skill for the authoring recipe.

```motoko
import Expose "mo:caffeineai-oql/Expose";

actor {
  // ... your storage ...
  include Expose({
    entities = [
      // default level is #controllerOnly when none is set
      customers.toEntity("customer", "Customer", "id").public_().build(),
      notes.toEntity("note", "Note", "id").ownedBy("owner").scopedPerUser().build(),
    ];
  });
}
```
