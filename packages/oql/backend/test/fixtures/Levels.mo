/// Per-table authorization fixture: one entity at each `TableAuth` level,
/// plus self-call probes. A canister calling itself presents its own
/// principal as `caller` — which is NOT one of its controllers — so the
/// probes exercise the non-controller branches that the controller-as-caller
/// test (Expose.test.mo's direct calls) cannot reach.

import Map       "mo:core/Map";
import Nat       "mo:core/Nat";
import Principal "mo:core/Principal";
import Text      "mo:core/Text";
import OQL       "../../src";
import Expose    "../../src/Expose";

actor class Levels() = self {

  // `privId` is a foreign key into `priv` (a #controllerOnly entity); only
  // the `pub` entity declares the edge, so it drives the schema edge-pruning
  // probe. `owner` drives the scoped levels.
  type Item = { id : Nat; owner : Principal; name : Text; privId : Nat };

  let someone = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");
  let me      = Principal.fromActor(self);

  func seed(m : Map.Map<Nat, Item>) {
    m.add(1, { id = 1; owner = someone; name = "one"; privId = 1 });
    m.add(2, { id = 2; owner = someone; name = "two"; privId = 1 });
  };

  let pub  : Map.Map<Nat, Item> = Map.empty(); do { seed(pub) };
  let priv : Map.Map<Nat, Item> = Map.empty(); do { seed(priv) };
  let mine : Map.Map<Nat, Item> = Map.empty(); do { seed(mine) };

  // `both` (#controllerOrScoped): two rows owned by `someone` plus one owned
  // by this canister's own principal. A controller sees all three; a
  // self-call (caller = this canister, a non-controller) sees only its one.
  let both : Map.Map<Nat, Item> = Map.empty();
  do {
    seed(both);
    both.add(3, { id = 3; owner = me; name = "mine-row"; privId = 1 });
  };

  include Expose({
    entities = [
      pub.toEntity("pub", "Item", "id").edge("privId", "priv").public_().build(),
      priv.toEntity("priv", "Item", "id").controllerOnly().build(),
      mine.toEntity("mine", "Item", "id").ownedBy("owner").scopedPerUser().build(),
      both.toEntity("both", "Item", "id").ownedBy("owner").controllerOrScoped().build(),
    ];
  });

  // ── Self-call probes (caller = self = non-controller, non-anonymous) ──

  /// A non-controller reads a #public_ entity: succeeds.
  public func selfReadsPublic() : async Bool {
    let r = await self.execute("{\"start\":\"pub\"}");
    r.rows.size() > 0
  };

  /// A non-controller is denied a #controllerOnly entity: traps.
  public func selfDeniedControllerOnly() : async Bool {
    try { ignore await self.execute("{\"start\":\"priv\"}"); false } catch _ { true }
  };

  /// A non-controller's schema() omits the #controllerOnly entity but keeps
  /// the #public_ one.
  public func selfSchemaHidesControllerOnly() : async Bool {
    let json = await self.schema();
    not has(json, "\"name\":\"priv\"") and has(json, "\"name\":\"pub\"")
  };

  /// A non-controller's schema() prunes the `pub.privId` edge because its
  /// target (`priv`) is denied — the edge pointer must not be advertised.
  public func selfSchemaPrunesDeniedEdge() : async Bool {
    let json = await self.schema();
    has(json, "\"name\":\"pub\"") and not has(json, "\"to\":\"priv\"")
  };

  /// Row count a non-controller (self-call) sees on the #controllerOrScoped
  /// `both` entity — should be only its own slice.
  public func selfBothCount() : async Nat {
    (await self.execute("{\"start\":\"both\"}")).rows.size()
  };

  func has(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));

};
