/// A more specific `?Text` instance in scope wins over `Entity`'s generic
/// `?T` one, so an app that already ships its own sentinel instance keeps its
/// behaviour; other optional fields still fall back to the generic instance.

import {test} "mo:test";
import OQL      "../src";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _Entity "../src/Entity";
import _NatValue "../src/NatValue";
import _TextValue "../src/TextValue";
import _RecordValue "../src/RecordValue";
import _OptTextSentinel "fixtures/OptTextSentinel";
import Executor "../src/Executor";
import Query    "../src/Query";
import Registry "../src/Registry";

type Row = { id : Nat; note : ?Text; score : ?Nat };

let rows : [Row] = [{ id = 1; note = null; score = null }];

let reg = Registry.build([
  OQL.Entity.new<Row>("r", func () = rows.values(), "Row", "id").build(),
]);

test("an app's own ?Text instance wins; ?Nat uses the generic one", func () {
  let q : Query.Query = {
    start = "r"; where_ = null; groupBy = []; aggregate = [];
    orderBy = []; offset = null; limit = null; select = null;
  };
  let r = Executor.runWith(reg, q, func (_ : OQL.Decl) : OQL.Access = #unrestricted);
  func cell(name : Text) : ?OQL.Value {
    for (c in r.rows[0].values()) { if (c.name == name) return ?c.value };
    null
  };
  assert cell("note")  == ?(#text(""));
  assert cell("score") == ?(#null_);
});
