/// Replica/PocketIC test for per-user scoping over the canister's Candid
/// surface, driven by the caller principal (no tokens). The `SelfScoped`
/// fixture exposes both entities `.scopedPerUser()`:
///
///   • `note` (`.ownedBy`): a caller sees the note it wrote, never one
///     owned by a different principal.
///   • `document` (`.ownedByWith` team rule): custom access composes with
///     a scoped level — the caller sees only docs of teams it belongs to.
///
/// Denial paths trap, and PocketIC turns a trap into a canister reject that
/// would crash runTests, so these assert the positive halves of the
/// contract (see Expose.test.mo for the denial probes).

import {test}      "mo:test/async";
import Text        "mo:core/Text";
import SelfScoped  "./fixtures/SelfScoped";

actor {

  func contains(haystack : Text, needle : Text) : Bool =
    Text.contains(haystack, #text(needle));

  type Cell = { name : Text; value : { #null_; #bool : Bool; #nat : Nat; #int : Int; #float : Float; #text : Text } };

  func cell(row : [Cell], name : Text) : ?Cell {
    for (c in row.values()) { if (c.name == name) return ?c };
    null
  };

  func natOf(c : Cell) : Nat = switch (c.value) { case (#nat n) n; case _ 0 };
  func textOf(c : Cell) : Text = switch (c.value) { case (#text t) t; case _ "" };

  public func runTests() : async () {

    let ss = await (with cycles = 10_000_000_000_000) SelfScoped.SelfScoped();

    await test("a scopedPerUser caller sees its own note, not another owner's", func () : async () {
      let myId = await ss.addNote("mine");        // owned by this test actor
      let r = await ss.execute("{\"start\":\"note\"}");
      assert r.rows.size() == 1;                  // only the caller's note
      switch (cell(r.rows[0], "id"))   { case (?c) { assert natOf(c) == myId }; case null { assert false } };
      switch (cell(r.rows[0], "body")) { case (?c) { assert textOf(c) == "mine" }; case null { assert false } };
    });

    await test("a custom (.ownedByWith) scheme authorizes by team membership", func () : async () {
      // Three docs across two teams; the caller joins only "alpha".
      ignore await ss.addDoc("alpha", "alpha doc");
      ignore await ss.addDoc("beta",  "beta doc");
      ignore await ss.addDoc("alpha", "another alpha doc");
      await ss.joinTeam("alpha");

      // Visible set is the two alpha docs; the beta doc is filtered out.
      let r = await ss.execute("{\"start\":\"document\"}");
      assert r.rows.size() == 2;
      for (row in r.rows.values()) {
        switch (cell(row, "team")) { case (?c) { assert textOf(c) == "alpha" }; case null { assert false } };
      };

      // The owner column of a custom-scheme entity still advertises role:owner.
      let json = await ss.schema();
      assert contains(json, "\"name\":\"team\",\"typeName\":\"Text\",\"role\":\"owner\"");
    });

  };

};
