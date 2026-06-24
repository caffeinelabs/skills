/// Build-time invariant probes. Each method constructs an entity that
/// `Entity.build()` must reject and returns `true` if `build()` trapped.
/// `build()` traps synchronously, which `mo:test` (sync) cannot catch — so
/// these run as canister methods whose trap surfaces as a catchable reject
/// in the async/replica suite.

import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Principal "mo:core/Principal";
import OQL       "../../src";

actor class BuildInvariants() {

  type Row = { id : Nat; owner : Principal };

  let rows : Map.Map<Nat, Row> = Map.empty();

  /// A scoped level with neither an owner column nor a subject-honouring
  /// source must trap at build.
  public func scopedNoOwnerTraps() : async () {
    ignore rows.toEntity("row", "Row", "id").scopedPerUser().build();
  };

  /// An owner column paired with #public_ (the check would never run) must
  /// trap at build.
  public func publicWithOwnerTraps() : async () {
    ignore rows.toEntity("row", "Row", "id").ownedBy("owner").public_().build();
  };

  /// A subject-honouring source (newScoped) with a scoped level is valid —
  /// must NOT trap, even without an owner column.
  public func newScopedScopedOk() : async Bool {
    let d = OQL.Entity.newScoped<Row>(
      "row", func (_ : ?Principal) = rows.values(), "Row", "id",
    ).scopedPerUser().build();
    d.auth == #scopedPerUser
  };

};
