import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import Time "mo:core/Time";

module {
  public type InviteStatus = {
    #valid;
    #expired;
    #revoked;
    #usedUp;
    #invalid;
  };

  public type RedeemResult = {
    #joined;
    #alreadyMember;
    #blocked;
    #expired;
    #revoked;
    #usedUp;
    #invalid;
  };

  public type Redemption = {
    user : Principal;
    at : Time.Time;
  };

  public type Invite = {
    name : Text;
    createdBy : Principal;
    createdAt : Time.Time;
    expiresAt : ?Time.Time;
    maxUses : ?Nat;
    var revoked : Bool;
    var redemptions : [Redemption];
  };

  public type InviteInfo = {
    code : Text;
    name : Text;
    createdBy : Principal;
    createdAt : Time.Time;
    expiresAt : ?Time.Time;
    maxUses : ?Nat;
    revoked : Bool;
    redemptions : [Redemption];
  };

  public type InvitesState = {
    var invites : Map.Map<Text, Invite>;
  };

  public func initState() : InvitesState {
    { var invites = Map.empty<Text, Invite>() };
  };

  // 128 bits of `raw_rand` keep links short and unguessable.
  public func codeFromSeed(seed : Blob) : Text {
    let digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
    let bytes = seed.toArray();
    if (bytes.size() < 16) {
      Runtime.trap("An invite code needs a seed of at least 16 bytes");
    };
    var code = "";
    for (byte in bytes.sliceToArray(0, 16).values()) {
      code #= digits[(byte >> 4).toNat()].toText() # digits[(byte & 0x0F).toNat()].toText();
    };
    code;
  };

  public func create(
    state : InvitesState,
    code : Text,
    name : Text,
    createdBy : Principal,
    now : Time.Time,
    expiresAt : ?Time.Time,
    maxUses : ?Nat,
  ) {
    switch (expiresAt) {
      case (?at) { if (at <= now) { Runtime.trap("An invite must expire in the future") } };
      case null {};
    };
    if (maxUses == ?0) {
      Runtime.trap("An invite must allow at least one use");
    };
    if (state.invites.containsKey(code)) {
      Runtime.trap("Invite code already exists");
    };
    state.invites.add(
      code,
      {
        name;
        createdBy;
        createdAt = now;
        expiresAt;
        maxUses;
        var revoked = false;
        var redemptions : [Redemption] = [];
      },
    );
  };

  public func status(state : InvitesState, code : Text, now : Time.Time) : InviteStatus {
    let ?invite = state.invites.get(code) else return #invalid;
    if (invite.revoked) { return #revoked };
    switch (invite.expiresAt) {
      case (?at) { if (now >= at) { return #expired } };
      case null {};
    };
    switch (invite.maxUses) {
      case (?max) { if (invite.redemptions.size() >= max) { return #usedUp } };
      case null {};
    };
    #valid;
  };

  public func recordRedemption(state : InvitesState, code : Text, user : Principal, now : Time.Time) {
    let ?invite = state.invites.get(code) else Runtime.trap("Invite not found");
    invite.redemptions := invite.redemptions.concat([{ user; at = now }]);
  };

  public func revoke(state : InvitesState, code : Text) {
    let ?invite = state.invites.get(code) else Runtime.trap("Invite not found");
    invite.revoked := true;
  };

  public func list(state : InvitesState) : [InviteInfo] {
    let infos = state.invites.entries().map(
      func((code, invite) : (Text, Invite)) : InviteInfo {
        {
          code;
          name = invite.name;
          createdBy = invite.createdBy;
          createdAt = invite.createdAt;
          expiresAt = invite.expiresAt;
          maxUses = invite.maxUses;
          revoked = invite.revoked;
          redemptions = invite.redemptions;
        };
      }
    ).toArray();
    infos.sort(func(a, b) = Int.compare(b.createdAt, a.createdAt));
  };
};
