/// Per-user scoping via the caller principal (no tokens). Both entities are
/// exposed `.scopedPerUser()`, so every authenticated caller sees only the
/// rows it owns. The companion test writes a note as itself (`addNote`) and
/// confirms it sees that note but never the pre-seeded note owned by a
/// different principal — exercising the subject = caller path over the wire.
/// `document` carries a custom `.ownedByWith` team rule to prove custom
/// access composes with a scoped level.

import Map       "mo:core/Map";
import List      "mo:core/List";
import Nat       "mo:core/Nat";
import Principal "mo:core/Principal";
import OQL       "../../src";
import Expose    "../../src/Expose";

actor class SelfScoped() = self {

  type Note = { id : Nat; owner : Principal; body : Text };
  type Doc  = { id : Nat; team : Text; title : Text };

  // A note owned by some other principal — must stay invisible to the
  // test caller, whose own principal differs.
  let other = Principal.fromText("rrkah-fqaaa-aaaaa-aaaaq-cai");

  let notes : Map.Map<Nat, Note> = Map.empty();
  do { notes.add(1, { id = 1; owner = other; body = "not yours" }) };

  let docs : Map.Map<Nat, Doc> = Map.empty();

  // App-specific authorization state for the custom (team) scheme.
  let teamsByMember : Map.Map<Principal, List.List<Text>> = Map.empty();

  /// Custom ownership rule: a caller sees a doc when it belongs to the
  /// team named in the row's owner column. Overrides principal equality.
  func onCallersTeam(caller : Principal, ownerColumn : OQL.Value) : Bool =
    switch ownerColumn {
      case (#text team) {
        switch (teamsByMember.get(caller)) {
          case (?teams) { teams.values().any(func (t : Text) : Bool = t == team) };
          case null     { false };
        };
      };
      case _ { false };
    };

  include Expose({
    entities = [
      notes.toEntity("note", "Note", "id")
        .ownedBy("owner")
        .scopedPerUser()
        .build(),
      docs.toEntity("document", "Doc", "id")
        .sample({ id = 0; team = ""; title = "" })   // docs is empty at init
        .ownedByWith("team", onCallersTeam)
        .scopedPerUser()
        .build(),
    ];
  });

  /// Store a note owned by the caller. Returns its id.
  public shared({caller}) func addNote(body : Text) : async Nat {
    let id = notes.size() + 1;
    notes.add(id, { id; owner = caller; body });
    id
  };

  public shared({caller}) func joinTeam(team : Text) : async () {
    let teams = switch (teamsByMember.get(caller)) {
      case (?l) { l };
      case null { let l = List.empty<Text>(); teamsByMember.add(caller, l); l };
    };
    teams.add(team);
  };

  public shared func addDoc(team : Text, title : Text) : async Nat {
    let id = docs.size() + 1;
    docs.add(id, { id; team; title });
    id
  };

};
