import Invites "../../src/invites";
import UserApproval "../../src/approval";

// Each instance is its own canister, so calls through it carry a principal other than the test runner's.
actor class Caller(
  backend : actor {
    _initialize_access_control : shared () -> async ();
    isCallerApproved : shared query () -> async Bool;
    requestApproval : shared () -> async ();
    setApproval : shared (Principal, UserApproval.ApprovalStatus) -> async ();
    removeApproval : shared Principal -> async ();
    listApprovals : shared query () -> async [UserApproval.UserApprovalInfo];
    createInvite : shared (Text, ?Nat, ?Int) -> async Text;
    listInvites : shared query () -> async [Invites.InviteInfo];
    revokeInvite : shared Text -> async ();
    checkInvite : shared query Text -> async Invites.InviteStatus;
    redeemInvite : shared Text -> async Invites.RedeemResult;
  }
) {
  public func register() : async () {
    await backend._initialize_access_control();
  };

  public func isCallerApproved() : async Bool {
    await backend.isCallerApproved();
  };

  public func requestApproval() : async () {
    await backend.requestApproval();
  };

  public func setApproval(user : Principal, status : UserApproval.ApprovalStatus) : async () {
    await backend.setApproval(user, status);
  };

  public func removeApproval(user : Principal) : async () {
    await backend.removeApproval(user);
  };

  public func listApprovals() : async [UserApproval.UserApprovalInfo] {
    await backend.listApprovals();
  };

  public func createInvite(name : Text, maxUses : ?Nat, expiresAt : ?Int) : async Text {
    await backend.createInvite(name, maxUses, expiresAt);
  };

  public func listInvites() : async [Invites.InviteInfo] {
    await backend.listInvites();
  };

  public func revokeInvite(code : Text) : async () {
    await backend.revokeInvite(code);
  };

  public func redeemInvite(code : Text) : async Invites.RedeemResult {
    await backend.redeemInvite(code);
  };
};
