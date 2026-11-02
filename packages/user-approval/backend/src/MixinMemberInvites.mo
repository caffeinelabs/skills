import AccessControl "mo:caffeineai-authorization/access-control";
import Invites "invites";
import UserApproval "approval";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Random "mo:core/Random";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";

mixin (
  accessControlState : AccessControl.AccessControlState,
  approvalState : UserApproval.UserApprovalState,
  invitesState : Invites.InvitesState,
) {
  public shared ({ caller }) func createInvite(name : Text, maxUses : ?Nat, expiresAt : ?Time.Time) : async Text {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can perform this action");
    };
    let code = Invites.codeFromSeed(await Random.blob());
    Invites.create(invitesState, code, name, caller, Time.now(), expiresAt, maxUses);
    code;
  };

  public query ({ caller }) func listInvites() : async [Invites.InviteInfo] {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can perform this action");
    };
    Invites.list(invitesState);
  };

  public shared ({ caller }) func revokeInvite(code : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can perform this action");
    };
    Invites.revoke(invitesState, code);
  };

  public query func checkInvite(code : Text) : async Invites.InviteStatus {
    Invites.status(invitesState, code, Time.now());
  };

  // A rejected user stays rejected: only removeApproval lets them back in.
  public shared ({ caller }) func redeemInvite(code : Text) : async Invites.RedeemResult {
    if (caller.isAnonymous()) {
      Runtime.trap("Sign in to accept an invite");
    };
    let now = Time.now();
    let status = Invites.status(invitesState, code, now);
    if (status == #invalid) { return #invalid };
    if (UserApproval.isApproved(approvalState, caller) or accessControlState.userRoles.get(caller) == ?#admin) {
      return #alreadyMember;
    };
    if (UserApproval.isRejected(approvalState, caller)) { return #blocked };
    switch (status) {
      case (#expired) { return #expired };
      case (#revoked) { return #revoked };
      case (#usedUp) { return #usedUp };
      case (#invalid) { return #invalid };
      case (#valid) {};
    };
    AccessControl.initialize(accessControlState, caller);
    UserApproval.setApproval(approvalState, caller, #approved);
    Invites.recordRedemption(invitesState, code, caller, now);
    #joined;
  };
};
