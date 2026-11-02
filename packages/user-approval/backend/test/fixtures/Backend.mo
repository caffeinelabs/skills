import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import MixinMemberInvites "../../src/MixinMemberInvites";
import MixinUserApproval "../../src/MixinUserApproval";
import Invites "../../src/invites";
import UserApproval "../../src/approval";

actor class Backend() {
  let accessControlState = AccessControl.initState();
  include MixinAuthorization(accessControlState, null);
  let approvalState = UserApproval.initState(accessControlState);
  include MixinUserApproval(accessControlState, approvalState);
  let invitesState = Invites.initState();
  include MixinMemberInvites(accessControlState, approvalState, invitesState);
};
