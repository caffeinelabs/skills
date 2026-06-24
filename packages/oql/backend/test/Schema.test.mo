/// Unit tests for the hand-rolled JSON serializer in `Schema.toJson`.
/// The assertions are substring-based; the goal is to catch shape
/// regressions, not to prove canonicalization.

import {test} "mo:test";
import Text   "mo:core/Text";
import Schema "../src/Schema";

func contains(haystack : Text, needle : Text) : Bool =
  Text.contains(haystack, #text(needle));

let doc : Schema.Document = {
  entities = [
    {
      name = "customer";
      typeName = "Customer";
      primaryKey = "id";
      fields = [
        { name = "id";      typeName = "Nat";  role = (#payload : Schema.Role); domain = null },
        { name = "country"; typeName = "Text"; role = (#payload : Schema.Role); domain = null },
        { name = "secret";  typeName = "Text"; role = (#hidden  : Schema.Role); domain = null },
        { name = "status";  typeName = "Text"; role = (#payload : Schema.Role);
          domain = ?[#text("active"), #text("inactive")] },
        { name = "owner";   typeName = "Text"; role = (#owner   : Schema.Role); domain = null },
      ];
    },
    {
      name = "order";
      typeName = "Order";
      primaryKey = "id";
      fields = [
        { name = "id";         typeName = "Nat"; role = (#payload : Schema.Role); domain = null },
        { name = "customerId"; typeName = "Nat"; role = (#edge({ to = "customer" }) : Schema.Role); domain = null },
      ];
    },
  ];
};

test("Schema.toJson contains every entity name", func () {
  let json = Schema.toJson(doc);
  assert contains(json, "\"name\":\"customer\"");
  assert contains(json, "\"name\":\"order\"");
});

test("Schema.toJson surfaces primaryKey and typeName", func () {
  let json = Schema.toJson(doc);
  assert contains(json, "\"primaryKey\":\"id\"");
  assert contains(json, "\"typeName\":\"Customer\"");
  assert contains(json, "\"typeName\":\"Order\"");
});

test("payload / hidden / edge / owner roles are distinguishable in output", func () {
  let json = Schema.toJson(doc);
  assert contains(json, "\"payload\"");
  assert contains(json, "\"hidden\"");
  // edge role is rendered as a nested object pointing at the target
  // entity name, which downstream tooling uses to traverse the graph.
  assert contains(json, "\"edge\":{\"to\":\"customer\"}");
  // owner role tells clients the entity is auto-scoped to the caller.
  assert contains(json, "\"name\":\"owner\",\"typeName\":\"Text\",\"role\":\"owner\"");
});

test("field metadata round-trips name and typeName", func () {
  let json = Schema.toJson(doc);
  assert contains(json, "\"name\":\"customerId\"");
  assert contains(json, "\"name\":\"country\"");
  assert contains(json, "\"typeName\":\"Text\"");
});

test("declared domain surfaces as a values array on the field", func () {
  let json = Schema.toJson(doc);
  // status field carries its enumerated arms; clients filter exactly.
  assert contains(json, "\"name\":\"status\"");
  assert contains(json, "\"values\":[\"active\",\"inactive\"]");
  // fields without a domain emit no values key.
  assert not contains(json, "\"name\":\"id\",\"typeName\":\"Nat\",\"role\":\"payload\",\"values\"");
});

test("escape: quotes and backslashes don't break the JSON", func () {
  let tricky : Schema.Document = {
    entities = [{
      name = "weird\"name";
      typeName = "T";
      primaryKey = "k";
      fields = [{ name = "back\\slash"; typeName = "Text"; role = #payload; domain = null }];
    }];
  };
  let json = Schema.toJson(tricky);
  assert contains(json, "weird\\\"name");
  assert contains(json, "back\\\\slash");
});
