/// Replica tests for `MixinUserApproval`. Runs under PocketIC via `mops test`.
///
/// The test runner registers first, so it is the admin. Each `Caller` fixture is a separate canister with its own principal.
/// A canister can never call as the anonymous principal, so the anonymous cases exercise the `approval` module directly.

import { test } "mo:test/async";
import Array "mo:core/Array";
import Map "mo:core/Map";
import Principal "mo:core/Principal";
import AccessControl "mo:caffeineai-authorization/access-control";
import UserApproval "../src/approval";
import Backend "./fixtures/Backend";
import Caller "./fixtures/Caller";

actor {
  // A trap inside `call` surfaces here as a reject, because a local async call runs as its own message.
  func traps(call : () -> async ()) : async Bool {
    try {
      await call();
      false;
    } catch _ {
      true;
    };
  };

  func statusOf(approvals : [UserApproval.UserApprovalInfo], user : Principal) : ?UserApproval.ApprovalStatus {
    switch (approvals.find(func info = info.principal == user)) {
      case (?info) { ?info.status };
      case null { null };
    };
  };

  public func runTests() : async () {
    let backend = await (with cycles = 10_000_000_000_000) Backend.Backend();
    await backend._initialize_access_control();
    let alice = await (with cycles = 10_000_000_000_000) Caller.Caller(backend);
    let stranger = await (with cycles = 10_000_000_000_000) Caller.Caller(backend);
    let aliceId = Principal.fromActor(alice);

    await test(
      "isCallerApproved returns false for a caller that never registered",
      func() : async () {
        assert not (await stranger.isCallerApproved());
      },
    );

    await test(
      "isCallerApproved returns true for the admin",
      func() : async () {
        assert await backend.isCallerApproved();
      },
    );

    await test(
      "requestApproval records the caller as pending",
      func() : async () {
        await alice.register();
        await alice.requestApproval();
        assert statusOf(await backend.listApprovals(), aliceId) == ?#pending;
        assert not (await alice.isCallerApproved());
      },
    );

    await test(
      "setApproval by the admin approves and then rejects a user",
      func() : async () {
        await backend.setApproval(aliceId, #approved);
        assert await alice.isCallerApproved();
        await backend.setApproval(aliceId, #rejected);
        assert not (await alice.isCallerApproved());
      },
    );

    await test(
      "requestApproval does not reopen a rejected user",
      func() : async () {
        await alice.requestApproval();
        assert statusOf(await backend.listApprovals(), aliceId) == ?#rejected;
      },
    );

    await test(
      "setApproval, removeApproval, and listApprovals trap for a non-admin",
      func() : async () {
        assert await traps(func() : async () { await alice.setApproval(aliceId, #approved) });
        assert await traps(func() : async () { await alice.removeApproval(aliceId) });
        assert await traps(func() : async () { ignore await alice.listApprovals() });
        assert statusOf(await backend.listApprovals(), aliceId) == ?#rejected;
      },
    );

    await test(
      "removeApproval by the admin lets a rejected user request approval again",
      func() : async () {
        await backend.removeApproval(aliceId);
        assert statusOf(await backend.listApprovals(), aliceId) == null;
        await alice.requestApproval();
        assert statusOf(await backend.listApprovals(), aliceId) == ?#pending;
      },
    );

    await test(
      "setApproval traps for the anonymous principal",
      func() : async () {
        assert await traps(func() : async () { await backend.setApproval(Principal.anonymous(), #approved) });
      },
    );

    await test(
      "requestApproval traps for the anonymous principal",
      func() : async () {
        let state = UserApproval.initState(AccessControl.initState());
        assert await traps(func() : async () { UserApproval.requestApproval(state, Principal.anonymous()) });
        assert state.approvalStatus.isEmpty();
      },
    );

    await test(
      "isApproved ignores an anonymous entry already in state",
      func() : async () {
        let state = UserApproval.initState(AccessControl.initState());
        state.approvalStatus.add(Principal.anonymous(), #approved);
        assert not UserApproval.isApproved(state, Principal.anonymous());
      },
    );
  };
};
