import Map "mo:core/Map";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import AccessControl "mo:caffeineai-authorization/access-control";

module {
  public type ApprovalStatus = {
    #approved;
    #rejected;
    #pending;
  };

  public type UserApprovalState = {
    var approvalStatus : Map.Map<Principal, ApprovalStatus>;
  };

  public func initState(accessControlState : AccessControl.AccessControlState) : UserApprovalState {
    var approvalStatus = Map.empty<Principal, ApprovalStatus>();
    for ((principal, role) in accessControlState.userRoles.entries()) {
      let status = if (role == #admin) {
        #approved;
      } else {
        #pending;
      };
      approvalStatus.add(principal, status);
    };
    { var approvalStatus };
  };

  // The anonymous check also covers state recorded before anonymous callers were rejected.
  public func isApproved(state : UserApprovalState, caller : Principal) : Bool {
    not caller.isAnonymous() and state.approvalStatus.get(caller) == ?#approved;
  };

  public func isRejected(state : UserApprovalState, user : Principal) : Bool {
    state.approvalStatus.get(user) == ?#rejected;
  };

  public func requestApproval(state : UserApprovalState, caller : Principal) {
    if (caller.isAnonymous()) {
      Runtime.trap("Anonymous principals cannot request approval");
    };
    if (state.approvalStatus.get(caller) == null) {
      setApproval(state, caller, #pending);
    };
  };

  // Approving the anonymous principal would approve every signed-out visitor.
  public func setApproval(state : UserApprovalState, user : Principal, approval : ApprovalStatus) {
    if (user.isAnonymous()) {
      Runtime.trap("The anonymous principal cannot be approved, rejected, or set to pending");
    };
    state.approvalStatus.add(user, approval);
  };

  // Unlike #rejected, a removed user can request approval again.
  public func removeApproval(state : UserApprovalState, user : Principal) {
    state.approvalStatus.remove(user);
  };

  public type UserApprovalInfo = {
    principal : Principal;
    status : ApprovalStatus;
  };

  public func listApprovals(state : UserApprovalState) : [UserApprovalInfo] {
    let infos = state.approvalStatus.map<Principal, ApprovalStatus, UserApprovalInfo>(
      func(principal, status) {
        {
          principal;
          status;
        };
      }
    );
    infos.values().toArray();
  };
};
