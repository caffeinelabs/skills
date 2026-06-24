/// Unit tests for `Auth.resolve`. In the sync `mo:test` runtime
/// `Principal.isController()` is callable and returns `false` for every
/// principal (there is no canister-controllers context), so every branch
/// EXCEPT `controller == true` is pinned here. The controller-sees-all
/// branches of `#controllerOnly` / `#controllerOrScoped` are covered over
/// the wire in the replica suite (Expose.test.mo), where the test actor is
/// a real controller of the fixture.

import {test}    "mo:test";
import Principal "mo:core/Principal";
import Auth      "../src/Auth";

let user = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");  // non-anonymous, non-controller here
let anon = Principal.fromText("2vxsx-fae");                    // the anonymous principal

// ── #public_ ──────────────────────────────────────────────────────────

test("#public_ is unrestricted for everyone (anonymous included)", func () {
  assert Auth.resolve(#public_, user) == #unrestricted;
  assert Auth.resolve(#public_, anon) == #unrestricted;
});

// ── #controllerOnly (non-controller rows) ─────────────────────────────

test("#controllerOnly denies a non-controller", func () {
  assert Auth.resolve(#controllerOnly, user) == #deny;
});

test("#controllerOnly denies the anonymous caller", func () {
  assert Auth.resolve(#controllerOnly, anon) == #deny;
});

// ── #scopedPerUser ────────────────────────────────────────────────────

test("#scopedPerUser scopes a non-anonymous caller to itself", func () {
  assert Auth.resolve(#scopedPerUser, user) == #scoped user;
});

test("#scopedPerUser denies the anonymous caller", func () {
  assert Auth.resolve(#scopedPerUser, anon) == #deny;
});

// ── #controllerOrScoped (non-controller rows) ─────────────────────────

test("#controllerOrScoped scopes a non-controller, non-anonymous caller", func () {
  assert Auth.resolve(#controllerOrScoped, user) == #scoped user;
});

test("#controllerOrScoped denies the anonymous caller", func () {
  assert Auth.resolve(#controllerOrScoped, anon) == #deny;
});
