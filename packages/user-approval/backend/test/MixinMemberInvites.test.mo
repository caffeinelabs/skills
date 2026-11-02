/// Replica tests for `MixinMemberInvites`. Runs under PocketIC via `mops test`.
///
/// The test runner registers first, so it is the admin. Each `Caller` fixture is a separate canister with its own principal.
/// Expiry needs a clock in the past, so it is exercised on the `invites` module directly.

import { test } "mo:test/async";
import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";
import Invites "../src/invites";
import Backend "./fixtures/Backend";
import Caller "./fixtures/Caller";

actor {
  func traps(call : () -> async ()) : async Bool {
    try {
      await call();
      false;
    } catch _ {
      true;
    };
  };

  func inviteOf(invites : [Invites.InviteInfo], code : Text) : Invites.InviteInfo {
    let ?invite = invites.find(func info = info.code == code) else Runtime.trap("Invite not listed");
    invite;
  };

  public func runTests() : async () {
    let backend = await (with cycles = 10_000_000_000_000) Backend.Backend();
    await backend._initialize_access_control();
    let alice = await (with cycles = 10_000_000_000_000) Caller.Caller(backend);
    let bob = await (with cycles = 10_000_000_000_000) Caller.Caller(backend);
    let carol = await (with cycles = 10_000_000_000_000) Caller.Caller(backend);
    let dave = await (with cycles = 10_000_000_000_000) Caller.Caller(backend);
    let aliceId = Principal.fromActor(alice);
    let bobId = Principal.fromActor(bob);
    let carolId = Principal.fromActor(carol);

    let code = await backend.createInvite("Friends", null, ?(Time.now() + 7 * 24 * 60 * 60 * 1_000_000_000));

    await test(
      "createInvite returns a 32-character hex code that checkInvite reports as valid",
      func() : async () {
        assert code.size() == 32;
        assert (await backend.checkInvite(code)) == #valid;
        assert (await backend.checkInvite("not-a-code")) == #invalid;
      },
    );

    await test(
      "createInvite, listInvites, and revokeInvite trap for a non-admin",
      func() : async () {
        assert await traps(func() : async () { ignore await alice.createInvite("Mine", null, null) });
        assert await traps(func() : async () { ignore await alice.listInvites() });
        assert await traps(func() : async () { await alice.revokeInvite(code) });
      },
    );

    await test(
      "createInvite traps for zero uses or an expiry in the past",
      func() : async () {
        assert await traps(func() : async () { ignore await backend.createInvite("Zero", ?0, null) });
        assert await traps(func() : async () { ignore await backend.createInvite("Past", null, ?(Time.now() - 1)) });
      },
    );

    await test(
      "redeemInvite approves a caller that never registered and records the redemption",
      func() : async () {
        assert not (await alice.isCallerApproved());
        assert (await alice.redeemInvite(code)) == #joined;
        assert await alice.isCallerApproved();
        let invite = inviteOf(await backend.listInvites(), code);
        assert invite.redemptions.size() == 1;
        assert invite.redemptions[0].user == aliceId;
      },
    );

    await test(
      "redeemInvite approves a pending caller",
      func() : async () {
        await bob.register();
        await bob.requestApproval();
        assert (await bob.redeemInvite(code)) == #joined;
        assert await bob.isCallerApproved();
      },
    );

    await test(
      "redeemInvite is idempotent for members and the admin",
      func() : async () {
        assert (await alice.redeemInvite(code)) == #alreadyMember;
        assert (await backend.redeemInvite(code)) == #alreadyMember;
        assert inviteOf(await backend.listInvites(), code).redemptions.size() == 2;
      },
    );

    await test(
      "a rejected user stays blocked until the admin removes the entry",
      func() : async () {
        await backend.setApproval(bobId, #rejected);
        assert (await bob.redeemInvite(code)) == #blocked;
        assert not (await bob.isCallerApproved());
        await backend.removeApproval(bobId);
        assert (await bob.redeemInvite(code)) == #joined;
      },
    );

    await test(
      "an invite with one use turns away the second caller",
      func() : async () {
        let single = await backend.createInvite("One", ?1, null);
        assert (await carol.redeemInvite(single)) == #joined;
        assert (await dave.redeemInvite(single)) == #usedUp;
        assert (await backend.checkInvite(single)) == #usedUp;
        assert not (await dave.isCallerApproved());
      },
    );

    await test(
      "revokeInvite stops new redemptions and keeps existing members",
      func() : async () {
        await backend.revokeInvite(code);
        assert (await backend.checkInvite(code)) == #revoked;
        assert (await dave.redeemInvite(code)) == #revoked;
        assert await alice.isCallerApproved();
        assert inviteOf(await backend.listInvites(), code).revoked;
      },
    );

    await test(
      "listInvites returns the newest invite first",
      func() : async () {
        let invites = await backend.listInvites();
        assert invites.size() == 2;
        assert invites[0].name == "One";
        assert invites[1].name == "Friends";
        assert invites[0].redemptions[0].user == carolId;
      },
    );

    await test(
      "status reports an invite as expired once its expiry passes",
      func() : async () {
        let state = Invites.initState();
        Invites.create(state, "c0de", "Soon", aliceId, 100, ?200, null);
        assert Invites.status(state, "c0de", 199) == #valid;
        assert Invites.status(state, "c0de", 200) == #expired;
      },
    );
  };
};
