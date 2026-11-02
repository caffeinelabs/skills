---
name: extension-user-approval
description: Approval-based user management with member invite links. Must-have for private apps and for apps with features that cost the owner money, so only approved members get in and admins invite people with links.
version: 1.2.0
compatibility:
  mops:
    caffeineai-user-approval: "~1.2.0"
    caffeineai-authorization: "~1.0.0"
  npm:
    "@caffeineai/user-approval": "~1.2.0"
caffeineai-subscription: [none]
---

# User Approval
User approval extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds approval-based user management. Users request access, or join through an invite link an admin shares; admins approve, reject, and remove members. Approved users gain access to protected features.

Signing in alone is not membership: with `extension-authorization`, every signed-in visitor gets the `#user` role. This skill is what keeps strangers out.

Invite links are part of every new app that uses this skill. When an existing app already uses `MixinUserApproval` without `MixinMemberInvites`, add invite links only when the user asks for them.

Prerequisite: You must follow [extension-authorization](../extension-authorization/SKILL.md) first, as this integration depends on it.

# Backend

## Module API

The prefabricated module `mo:caffeineai-user-approval/approval` provides low-level approval state management. Do not modify it.

```mo:caffeineai-user-approval/approval
import AccessControl "mo:caffeineai-authorization/access-control";

module {
    public type ApprovalStatus = {
        #approved;
        #rejected;
        #pending;
    };

    public type UserApprovalState = { /* internal state */ };

    public func initState(accessControlState: AccessControl.AccessControlState) : UserApprovalState;

    public func isApproved(state : UserApprovalState, caller : Principal) : Bool;
    public func isRejected(state : UserApprovalState, user : Principal) : Bool;
    public func requestApproval(state : UserApprovalState, caller : Principal);
    public func setApproval(state : UserApprovalState, user : Principal, approval : ApprovalStatus);
    public func removeApproval(state : UserApprovalState, user : Principal);

    public type UserApprovalInfo = {
        principal : Principal;
        status : ApprovalStatus;
    };

    public func listApprovals(state : UserApprovalState) : [UserApprovalInfo];
}
```

The prefabricated module `mo:caffeineai-user-approval/invites` provides invite-link state. Do not modify it.

```mo:caffeineai-user-approval/invites
module {
    public type InviteStatus = { #valid; #expired; #revoked; #usedUp; #invalid };

    public type RedeemResult = { #joined; #alreadyMember; #blocked; #expired; #revoked; #usedUp; #invalid };

    public type Redemption = { user : Principal; at : Time.Time };

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

    public type InvitesState = { /* internal state */ };

    public func initState() : InvitesState;
}
```

## Setup in main.mo

`include MixinUserApproval(accessControlState, approvalState)` and `include MixinMemberInvites(accessControlState, approvalState, invitesState)` MUST be placed in `main.mo`, not in a custom mixin file. Declare `approvalState` and `invitesState` at actor top level and pass them into the mixins. `MixinUserApproval` provides these public endpoints automatically:

- `isCallerApproved()`
- `requestApproval()`
- `setApproval(user, status)`
- `removeApproval(user)`
- `listApprovals()`

`MixinMemberInvites` provides these:

- `createInvite(name, maxUses, expiresAt)` (admin only): returns the new invite code. `name` is the admin's own label for the link, `maxUses = null` allows unlimited uses, and `expiresAt = null` never expires. It traps for zero uses or an expiry in the past
- `listInvites()` (admin only): every invite, newest first, with its code and who joined through it
- `revokeInvite(code)` (admin only): stops new joins through the link; members who already joined stay
- `checkInvite(code)`: a query anyone can call, returning the link's `InviteStatus`
- `redeemInvite(code)`: approves the signed-in caller and returns a `RedeemResult`. Members and admins get `#alreadyMember`; a rejected user gets `#blocked` and stays rejected until an admin calls `removeApproval`. It traps for the anonymous principal

Keep `approvalState` in scope for custom approval guards in app-specific endpoints.

Do NOT redeclare any of the mixin-provided functions.

```motoko filepath=src/backend/main.mo
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import MixinMemberInvites "mo:caffeineai-user-approval/MixinMemberInvites";
import MixinUserApproval "mo:caffeineai-user-approval/MixinUserApproval";
import Invites "mo:caffeineai-user-approval/invites";
import UserApproval "mo:caffeineai-user-approval/approval";
import Runtime "mo:core/Runtime";

actor {
  let accessControlState : AccessControl.AccessControlState;
  include MixinAuthorization(accessControlState, null);
  let approvalState : UserApproval.UserApprovalState;
  include MixinUserApproval(accessControlState, approvalState);
  let invitesState : Invites.InvitesState;
  include MixinMemberInvites(accessControlState, approvalState, invitesState);

  // Example custom endpoint with an approval guard:
  // public shared ({ caller }) func protectedFeature() : async () {
  //     if (not (UserApproval.isApproved(approvalState, caller) or AccessControl.hasPermission(accessControlState, caller, #admin))) {
  //         Runtime.trap("Unauthorized: Only approved users can perform this action");
  //     };
  // };
};
```

The migration chain head — `UserApproval.initState` depends on the access-control state, so compute it in order inside the migration body:

```motoko filepath=src/backend/migrations/00000000_000000.mo
import AccessControl "mo:caffeineai-authorization/access-control";
import Invites "mo:caffeineai-user-approval/invites";
import UserApproval "mo:caffeineai-user-approval/approval";

module {
  type NewActor = {
    accessControlState : AccessControl.AccessControlState;
    approvalState : UserApproval.UserApprovalState;
    invitesState : Invites.InvitesState;
  };

  public func migration(_old : {}) : NewActor {
    let accessControlState = AccessControl.initState();
    {
      accessControlState;
      approvalState = UserApproval.initState(accessControlState);
      invitesState = Invites.initState();
    };
  };
};
```

To add invite links to an existing app, add `invitesState` and the `MixinMemberInvites` include to `main.mo`, and supply the new field from a new migration file (see `migrating-motoko-actors`); never edit the chain head of a deployed app:

<!-- motoko-check:skip -->
```motoko filepath=src/backend/migrations/20261030_000000.mo
import Invites "mo:caffeineai-user-approval/invites";

module {
  public func migration(_old : {}) : { invitesState : Invites.InvitesState } {
    { invitesState = Invites.initState() };
  };
};
```

On `initState`, existing admins are automatically approved. All other users are pending.

The anonymous principal is never approved: `requestApproval` and `setApproval` trap for it, and `isCallerApproved` returns `false`. `isCallerApproved` also returns `false`, rather than trapping, for a signed-in caller that has not registered yet.

IMPORTANT: Apply the right authorization and/or approval check to each custom public function.

# Frontend

# User Approval Flow
- Check approval status (`isCallerApproved`)
- If not approved, show option to request approval (`requestApproval`). Show it only to signed-in users; it traps for the anonymous principal
- Block access to main features for non-approved users
- Admins have access to all features of the application
- Display approval status clearly in the UI

# Invite Links

Install `@caffeineai/user-approval`. It exports the prefabricated hook `useInviteRedemption` and the helper `inviteLink`, which cannot be modified:

```typescript filepath=@caffeineai/user-approval/hooks/useInviteRedemption.ts
export interface MemberInvitesActor {
  checkInvite(code: string): Promise<string>;
  redeemInvite(code: string): Promise<string>;
}

export type InviteStatus = 'valid' | 'expired' | 'revoked' | 'usedUp' | 'invalid';
export type RedeemOutcome = 'joined' | 'alreadyMember' | 'blocked' | 'expired' | 'revoked' | 'usedUp' | 'invalid';

// none: no invite in the URL or pending from an earlier visit
// checking / redeeming: the backend call is in flight
// an InviteStatus while signed out, a RedeemOutcome once signed in
// error: the backend call failed; `error` holds the message
export type InviteRedemptionStatus = 'none' | 'checking' | 'redeeming' | 'error' | InviteStatus | RedeemOutcome;

// Builds the shareable link `https://<app origin>/?invite=<code>`
export declare function inviteLink(code: string): string;

// Takes `?invite=` from the URL, removes it from the address bar, and keeps it
// across sign-in. Signed out, it checks the invite; signed in, it redeems it once.
export declare function useInviteRedemption(
  actor: MemberInvitesActor | null | undefined,
  isAuthenticated: boolean,
  options?: { onJoined?: () => void },
): {
  code: string | null;
  status: InviteRedemptionStatus;
  error: string | null;
  hasInvite: boolean;
  retry: () => void;
  dismiss: () => void;
};
```

Rules for invite links:

- Call `useInviteRedemption` once, in the root layout that renders on every route, so an invite link opened on any page works. Pass `isAuthenticated` from `useInternetIdentity`.
- While `hasInvite` is true, show an invite screen in place of the "request access" screen:
  - `valid` while signed out: say the visitor was invited, with a sign-in button.
  - `checking` or `redeeming`: a loading state.
  - `joined`: a welcome message, then the app.
  - `alreadyMember`: go straight to the app.
  - `expired`, `revoked`, `usedUp`, `invalid`: say the link no longer works and to ask the admin for a new one, with `dismiss()` to continue.
  - `blocked`: say access was removed, with `dismiss()`.
  - `error`: show `error` with a `retry()` button.
- In `onJoined`, invalidate the queries that read approval status (for example `isCallerApproved`) so the app unlocks without a reload.

Example root layout:

```typescript filepath=src/frontend/src/components/InviteGate.tsx
import { useQueryClient } from '@tanstack/react-query';
import { useActor, useInternetIdentity } from '@caffeineai/core-infrastructure';
import { useInviteRedemption } from '@caffeineai/user-approval';
import { createActor } from '@/backend';

export function InviteGate({ children }: { children: React.ReactNode }) {
  const { actor } = useActor(createActor);
  const { isAuthenticated, login } = useInternetIdentity();
  const queryClient = useQueryClient();
  const { status, error, hasInvite, retry, dismiss } = useInviteRedemption(actor, isAuthenticated, {
    onJoined: () => void queryClient.invalidateQueries(),
  });

  if (!hasInvite || status === 'joined' || status === 'alreadyMember') return <>{children}</>;
  if (status === 'valid') return <button onClick={() => login()}>You're invited. Sign in to join</button>;
  if (status === 'checking' || status === 'redeeming' || status === 'none') return <p>Checking your invite…</p>;
  if (status === 'error') return <p>{error} <button onClick={retry}>Try again</button></p>;
  if (status === 'blocked') return <p>Your access was removed. <button onClick={dismiss}>Continue</button></p>;
  return <p>This invite link no longer works. Ask the admin for a new one. <button onClick={dismiss}>Continue</button></p>;
}
```

# Admin Dashboard
For admin users, provide one members page with three tabs:

- **Requests**: users with `#pending` status from `listApprovals`, with approve and reject buttons (`setApproval`). A rejected user cannot request approval again
- **Invites**: a "Create invite link" form and the list from `listInvites`
  - The form asks for a name, a use limit, and an expiry. Default to unlimited uses and an expiry 7 days from now; offer "single use" and "never expires"
  - Pass `expiresAt` in nanoseconds: `BigInt(date.getTime()) * 1_000_000n`
  - Show each invite's name, status (active, expired, used up, or revoked), uses, expiry, and the people who joined through it
  - Each active invite has a "Copy link" button that copies `inviteLink(code)`, and a "Revoke" button (`revokeInvite`)
- **Members**: users with `#approved` status, with the invite they joined through (match `redemptions` from `listInvites`), their role, and these actions:
  - "Remove" sets `#rejected` (`setApproval`), which also blocks their invite links
  - "Allow again" on a rejected user calls `removeApproval`, so they can request access or use a link again
  - View and assign user roles (using `getCallerUserRole` and `assignCallerUserRole`)

# Backend Integration
The backend already implements the following functionality.
The full interface can be found in <backend-interface>

// Check if current user is approved, admins are always approved
isCallerApproved(): Promise<boolean>;

// Submit approval request
requestApproval(): Promise<void>;

// Get all users and their approval status (admin only)
listApprovals(): Promise<Array<UserApprovalInfo>>;

// Approve or reject a user (admin only)
setApproval(user: Principal, status: ApprovalStatus): Promise<void>;

// Delete a user's approval entry, so they can request approval again (admin only)
removeApproval(user: Principal): Promise<void>;

// Create an invite link code (admin only); null means unlimited uses or no expiry
createInvite(name: string, maxUses: bigint | null, expiresAt: bigint | null): Promise<string>;

// All invites, newest first, with who joined through each (admin only)
listInvites(): Promise<Array<InviteInfo>>;

// Stop new joins through an invite (admin only)
revokeInvite(code: string): Promise<void>;

// Check an invite without signing in
checkInvite(code: string): Promise<InviteStatus>;

// Join through an invite as the signed-in caller
redeemInvite(code: string): Promise<RedeemResult>;

// Assign a role to a user (admin only)
assignCallerUserRole(user: Principal, role: UserRole): Promise<void>;

// Get current role for a specific user
getCallerUserRole(): Promise<UserRole>;
