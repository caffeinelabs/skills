/// Replica test for the `Expose` mixin and per-table authorization. Runs
/// under PocketIC via `mops test --mode replica --replica pocket-ic`.
///
/// The test actor IS each fixture's controller (PocketIC installs it that
/// way), so direct calls exercise the controller branch. The `Levels`
/// fixture's self-call probes reach the non-controller branch (a canister
/// calling itself is not its own controller). `BuildInvariants` proves the
/// build-time guards trap (a trap surfaces as a catchable reject here,
/// which sync `mo:test` cannot do).

import {test}           "mo:test/async";
import Text             "mo:core/Text";
import Queryable        "./fixtures/Queryable";
import Levels           "./fixtures/Levels";
import BuildInvariants  "./fixtures/BuildInvariants";

actor {

  func contains(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));

  public func runTests() : async () {

    // ── Queryable: default level (#controllerOnly), controller caller ──

    let queryable = await (with cycles = 10_000_000_000_000) Queryable.Queryable();

    await test("schema() returns JSON with the declared entity", func() : async () {
      let json = await queryable.schema();
      assert contains(json, "\"name\":\"customer\"");
      assert contains(json, "\"typeName\":\"Customer\"");
      assert contains(json, "\"primaryKey\":\"id\"");
    });

    await test("schema() surfaces every payload field of the entity", func() : async () {
      let json = await queryable.schema();
      assert contains(json, "\"name\":\"id\"");
      assert contains(json, "\"name\":\"name\"");
      assert contains(json, "\"name\":\"country\"");
      assert contains(json, "\"payload\"");
    });

    await test("controller execute() reads a #controllerOnly entity", func() : async () {
      let r = await queryable.execute("{\"start\":\"customer\"}");
      assert r.rows.size() == 3;
    });

    // ── Levels: one entity per TableAuth level ──

    let levels = await (with cycles = 10_000_000_000_000) Levels.Levels();

    await test("controller schema() sees every level's entity and keeps the edge", func() : async () {
      let json = await levels.schema();
      assert contains(json, "\"name\":\"pub\"");
      assert contains(json, "\"name\":\"priv\"");
      assert contains(json, "\"name\":\"mine\"");
      assert contains(json, "\"name\":\"both\"");
      // the pub.privId edge points at priv, which the controller may read.
      assert contains(json, "\"to\":\"priv\"");
    });

    await test("controller execute() reads #public_ and #controllerOnly fully", func() : async () {
      assert (await levels.execute("{\"start\":\"pub\"}")).rows.size() == 2;
      assert (await levels.execute("{\"start\":\"priv\"}")).rows.size() == 2;
    });

    await test("#controllerOrScoped: controller sees all rows, scoped caller sees only its own", func() : async () {
      // controller (this test actor) -> #unrestricted -> all three rows.
      assert (await levels.execute("{\"start\":\"both\"}")).rows.size() == 3;
      // self-call (non-controller) -> #scoped self -> only the row it owns.
      assert (await levels.selfBothCount()) == 1;
    });

    await test("non-controller (self-call) reads #public_ but is denied #controllerOnly", func() : async () {
      assert (await levels.selfReadsPublic());
      assert (await levels.selfDeniedControllerOnly());
    });

    await test("non-controller schema() hides #controllerOnly and prunes the edge to it", func() : async () {
      assert (await levels.selfSchemaHidesControllerOnly());
      assert (await levels.selfSchemaPrunesDeniedEdge());
    });

    // ── Build-time invariants: offending entities trap at build ──

    let bad = await (with cycles = 10_000_000_000_000) BuildInvariants.BuildInvariants();

    await test("scoped level without owner/scoped-source traps at build", func() : async () {
      let trapped = try { await bad.scopedNoOwnerTraps(); false } catch _ { true };
      assert trapped;
    });

    await test("owner column with #public_ traps at build", func() : async () {
      let trapped = try { await bad.publicWithOwnerTraps(); false } catch _ { true };
      assert trapped;
    });

    await test("newScoped + scoped level is valid (no trap)", func() : async () {
      assert (await bad.newScopedScopedOk());
    });

  };

};
