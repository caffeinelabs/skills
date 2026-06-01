import AccessControl "./access-control";
import Challenges "mo:identity-attributes/Internal/Challenges";
import Verify     "mo:identity-attributes/Internal/Verify";
import Result     "mo:core/Result";

mixin (
  accessControlState : AccessControl.AccessControlState,
  onAttributesVerified : ?((Principal, Verify.IdentityAttributes) -> ()),
) {
  transient let challenges = Challenges.empty();

  public shared func _internet_identity_sign_in_start() : async Blob {
    await Challenges.issue<system>(challenges)
  };

  public shared ({ caller }) func _internet_identity_sign_in_finish()
    : async Result.Result<(), Verify.Error>
  {
    AccessControl.initialize(accessControlState, caller);
    switch (Verify.verify<system>(challenges)) {
      case (#err e) #err e;
      case (#ok attrs) {
        switch (onAttributesVerified) {
          case null {};
          case (?cb) { cb(caller, attrs) };
        };
        #ok
      };
    }
  };

  public shared ({ caller }) func _initialize_access_control()
    : async ()
  {
    AccessControl.initialize(accessControlState, caller);
  };

  public query ({ caller }) func getCallerUserRole() : async AccessControl.UserRole {
    AccessControl.getUserRole(accessControlState, caller);
  };

  public shared ({ caller }) func assignCallerUserRole(user : Principal, role : AccessControl.UserRole) : async () {
    AccessControl.assignRole(accessControlState, caller, user, role);
  };

  public query ({ caller }) func isCallerAdmin() : async Bool {
    AccessControl.isAdmin(accessControlState, caller);
  };
};
