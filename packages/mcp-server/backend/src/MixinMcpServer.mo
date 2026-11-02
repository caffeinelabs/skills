import Runtime "mo:core/Runtime";
import Time "mo:core/Time";
import AccessControl "mo:caffeineai-authorization/access-control";
import Mcp "Mcp";
import OAuth "OAuth";

// Candid methods the app's frontend calls: the admin's connector settings,
// the `/mcp-authorize` consent page, and the user's list of connections.
mixin (mcpState : Mcp.State, accessControlState : AccessControl.AccessControlState) {
  public shared ({ caller }) func _caffeineMcpSetSignInOrigin(origin : Text) : async () {
    if (not AccessControl.isAdmin(accessControlState, caller)) {
      Runtime.trap("Unauthorized: only admins can set the sign-in origin");
    };
    if (not OAuth.validSignInOrigin(origin)) {
      Runtime.trap("Invalid origin: use https://<host> with no path");
    };
    mcpState.signInOrigin := ?origin;
  };

  public query func _caffeineMcpSignInOrigin() : async ?Text {
    mcpState.signInOrigin;
  };

  public query func _caffeineMcpClient(clientId : Text) : async ?{
    name : Text;
    redirectUris : [Text];
  } {
    OAuth.client(mcpState, clientId);
  };

  public shared ({ caller }) func _caffeineMcpApprove(request : OAuth.Approval) : async {
    #ok : Text;
    #err : Text;
  } {
    await* OAuth.approve(mcpState, caller, request, Time.now());
  };

  public query ({ caller }) func _caffeineMcpConnections() : async [OAuth.Connection] {
    OAuth.connections(mcpState, caller);
  };

  public shared ({ caller }) func _caffeineMcpRevoke(id : Text) : async () {
    OAuth.revoke(mcpState, caller, id);
  };
};
