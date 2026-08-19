/// A deployed canister holding an `IndexedMap` as its state, for the PocketIC
/// end-to-end test. Writes are update methods (`add`/`remove`), reads are query
/// methods exposing BOTH the index-served and the scan path for the same shape,
/// so the test can assert they agree over real canister state reached through
/// real IC message calls.
///
/// `users` is a plain (default-persistent) `var`, NOT `transient` — that is the
/// whole point of the pure-data design: `IndexedMap` stores no function values
/// (the comparator and row lineariser are implicit per-call arguments, like
/// `mo:core`'s `Map`), so it is stable and survives an upgrade directly. The
/// fact that this field COMPILES as persistent is the proof.

import Array      "mo:core/Array";
import List       "mo:core/List";
import Nat        "mo:core/Nat";
import IndexedMap "../../src/IndexedMap";
import OQL        "../../src";   // brings the implicit `_toRow` instances into scope
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _NatValue "../../src/NatValue";
import _TextValue "../../src/TextValue";
import _RecordValue "../../src/RecordValue";

actor class IndexedStore() = self {

  type User = { id : Nat; email : Text; age : Nat };

  // Persistent canister state — no `transient`, no rebuild-on-upgrade.
  var users = IndexedMap.new<Nat, User>([("email", #hash), ("age", #ordered)]);

  func idsSorted(it : { next : () -> ?(Nat, User) }, pred : User -> Bool) : [Nat] {
    let acc = List.empty<Nat>();
    for ((k, u) in it) { if (pred(u)) acc.add(k) };
    Array.sort(acc.toArray(), Nat.compare)
  };

  // ── writes (update calls) ──────────────────────────────────────────────
  public func add(id : Nat, email : Text, age : Nat) : async () {
    users.put(id, { id; email; age });
  };
  public func remove(id : Nat) : async () { users.delete(id) };

  // ── reads (query calls) ────────────────────────────────────────────────
  public query func size() : async Nat { users.size() };

  // age >= t, two ways
  public query func ageAtLeastIndex(t : Nat) : async [Nat] =
    async idsSorted(users.candidatesRange("age", ?#nat(t), null, #asc), func u = u.age >= t);
  public query func ageAtLeastScan(t : Nat) : async [Nat] =
    async idsSorted(users.entries(), func u = u.age >= t);

  // email == e, two ways
  public query func byEmailIndex(e : Text) : async [Nat] =
    async idsSorted(users.candidatesEq("email", #text(e)), func u = u.email == e);
  public query func byEmailScan(e : Text) : async [Nat] =
    async idsSorted(users.entries(), func u = u.email == e);

};
