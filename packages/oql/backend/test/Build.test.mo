/// Unit tests for the `Entity.build` authorization invariants — the
/// POSITIVE (must-build) cases, which `mo:test` (sync) can assert directly
/// because they do not trap. The NEGATIVE (must-trap) cases run in the
/// replica suite (Expose.test.mo via BuildInvariants), since a build trap
/// cannot be caught synchronously.

import {test}    "mo:test";
import Map       "mo:core/Map";
import Principal "mo:core/Principal";
import OQL       "../src";

type Owned = { id : Nat; owner : Principal };

let owned : Map.Map<Nat, Owned> = Map.empty();
do { owned.add(1, { id = 1; owner = Principal.fromText("aaaaa-aa") }) };

test("default level is #controllerOnly", func () {
  let d = owned.toEntity("o", "Owned", "id").build();
  assert d.auth == #controllerOnly;
});

test("#public_ without an owner column builds", func () {
  let d = owned.toEntity("o", "Owned", "id").public_().build();
  assert d.auth == #public_;
});

test(".ownedBy + #controllerOnly builds (owner tag, controller sees all)", func () {
  let d = owned.toEntity("o", "Owned", "id").ownedBy("owner").controllerOnly().build();
  assert d.auth == #controllerOnly;
});

test(".ownedBy + #scopedPerUser builds", func () {
  let d = owned.toEntity("o", "Owned", "id").ownedBy("owner").scopedPerUser().build();
  assert d.auth == #scopedPerUser;
});

test(".ownedBy + #controllerOrScoped builds", func () {
  let d = owned.toEntity("o", "Owned", "id").ownedBy("owner").controllerOrScoped().build();
  assert d.auth == #controllerOrScoped;
});

test("newScoped + #scopedPerUser builds without an owner column", func () {
  let d = OQL.Entity.newScoped<Owned>(
    "o", func (_ : ?Principal) = owned.values(), "Owned", "id",
  ).scopedPerUser().build();
  assert d.auth == #scopedPerUser;
});
