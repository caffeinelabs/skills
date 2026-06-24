/// Unit tests for the JSON → `Query` parser. Pure module — no replica
/// needed. Each test sends a JSON string and asserts on the resulting
/// `Query.Query` AST shape.

import {test} "mo:test";
import Json   "../src/Json";

func okQuery(text : Text) : Json.ParseResult = Json.parseQuery(text);

test("minimum query: just a start entity", func () {
  switch (okQuery("{\"start\":\"customer\"}")) {
    case (#err e) { assert false; ignore e };
    case (#ok q)  {
      assert q.start == "customer";
      assert q.where_ == null;
      assert q.orderBy.size() == 0;
      assert q.offset == null;
      assert q.limit  == null;
      assert q.select == null;
    };
  };
});

test("missing start is rejected with a useful error", func () {
  switch (okQuery("{}")) {
    case (#err _) { assert true };
    case (#ok _)  { assert false };
  };
});

test("eq predicate parses field + value", func () {
  let json = "{\"start\":\"customer\",\"where\":{\"eq\":{\"field\":\"country\",\"value\":\"DE\"}}}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#eq(path, #text v)) { assert path == ["country"]; assert v == "DE" };
        case _ { assert false };
      };
    };
  };
});

test("nested and / or / not", func () {
  let json = "{\"start\":\"customer\",\"where\":{\"and\":["
    # "{\"or\":[{\"eq\":{\"field\":\"country\",\"value\":\"DE\"}},"
    #          "{\"eq\":{\"field\":\"country\",\"value\":\"FR\"}}]},"
    # "{\"not\":{\"eq\":{\"field\":\"name\",\"value\":\"charlie\"}}}]}}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#and_ parts) {
          assert parts.size() == 2;
          switch (parts[0]) {
            case (#or_ branches) { assert branches.size() == 2 };
            case _ { assert false };
          };
          switch (parts[1]) {
            case (#not_ inner) {
              switch inner {
                case (#eq _) { assert true };
                case _ { assert false };
              };
            };
            case _ { assert false };
          };
        };
        case _ { assert false };
      };
    };
  };
});

test("orderBy with explicit direction; default direction is asc", func () {
  let json = "{\"start\":\"customer\",\"orderBy\":["
    # "{\"field\":\"country\",\"dir\":\"asc\"},"
    # "{\"field\":\"name\"}]}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      assert q.orderBy.size() == 2;
      assert q.orderBy[0].field == ["country"];
      assert q.orderBy[0].dir   == #asc;
      assert q.orderBy[1].field == ["name"];
      assert q.orderBy[1].dir   == #asc;
    };
  };
});

test("offset + limit + select", func () {
  let json = "{\"start\":\"customer\",\"offset\":2,\"limit\":5,\"select\":[\"id\",\"name\"]}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      assert q.offset == ?2;
      assert q.limit  == ?5;
      switch (q.select) {
        case (?paths) { assert paths.size() == 2; assert paths[0] == ["id"]; assert paths[1] == ["name"] };
        case null { assert false };
      };
    };
  };
});

test("negative limit / offset / unknown op produce errors", func () {
  switch (okQuery("{\"start\":\"x\",\"limit\":-1}"))       { case (#err _) { assert true }; case _ { assert false } };
  switch (okQuery("{\"start\":\"x\",\"offset\":-3}"))      { case (#err _) { assert true }; case _ { assert false } };
  switch (okQuery("{\"start\":\"x\",\"where\":{\"xx\":1}}")) {
    case (#err _) { assert true };
    case _ { assert false };
  };
});

test("malformed JSON returns an err, not a trap", func () {
  switch (okQuery("not json at all")) {
    case (#err _) { assert true };
    case (#ok _)  { assert false };
  };
});

test("in predicate parses field + scalar array", func () {
  let json = "{\"start\":\"article\",\"where\":"
    # "{\"in\":{\"field\":\"authorId\",\"value\":[1,2,5]}}}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#in_(path, vs)) {
          assert path == ["authorId"];
          assert vs.size() == 3;
          assert vs[0] == #nat(1);
          assert vs[1] == #nat(2);
          assert vs[2] == #nat(5);
        };
        case _ { assert false };
      };
    };
  };
});

test("in with empty value array parses (matches nothing at eval time)", func () {
  let json = "{\"start\":\"article\",\"where\":{\"in\":{\"field\":\"id\",\"value\":[]}}}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#in_(_, vs)) { assert vs.size() == 0 };
        case _ { assert false };
      };
    };
  };
});

test("in rejects non-array value with a clear error", func () {
  switch (okQuery("{\"start\":\"x\",\"where\":{\"in\":{\"field\":\"id\",\"value\":5}}}")) {
    case (#err _) { assert true };
    case _        { assert false };
  };
});

test("text-search ops parse field + string value", func () {
  let cases : [(Text, Text)] = [
    ("contains", "refund"), ("icontains", "Refund"),
    ("startsWith", "Re"), ("endsWith", "und"),
  ];
  for ((op, needle) in cases.values()) {
    let json = "{\"start\":\"thread\",\"where\":{\"" # op
      # "\":{\"field\":\"subject\",\"value\":\"" # needle # "\"}}}";
    switch (okQuery(json)) {
      case (#err _) { assert false };
      case (#ok q)  {
        let (path, v) = switch (q.where_) {
          case (?#contains   pv) { assert op == "contains";   pv };
          case (?#icontains  pv) { assert op == "icontains";  pv };
          case (?#startsWith pv) { assert op == "startsWith"; pv };
          case (?#endsWith   pv) { assert op == "endsWith";   pv };
          case _ { assert false; (([] : [Text]), #null_) };
        };
        assert path == ["subject"];
        assert v == #text(needle);
      };
    };
  };
});

test("text-search ops reject non-string values at parse time", func () {
  switch (okQuery("{\"start\":\"x\",\"where\":{\"contains\":{\"field\":\"subject\",\"value\":42}}}")) {
    case (#err _) { assert true };
    case _        { assert false };
  };
  switch (okQuery("{\"start\":\"x\",\"where\":{\"icontains\":{\"field\":\"subject\",\"value\":null}}}")) {
    case (#err _) { assert true };
    case _        { assert false };
  };
  switch (okQuery("{\"start\":\"x\",\"where\":{\"startsWith\":{\"field\":\"subject\"}}}")) {
    case (#err _) { assert true };
    case _        { assert false };
  };
});

test("dotted paths split into segments in every field position", func () {
  let json = "{\"start\":\"emp\","
    # "\"where\":{\"eq\":{\"field\":\"dept.name\",\"value\":\"eng\"}},"
    # "\"groupBy\":[\"dept.name\"],"
    # "\"aggregate\":[{\"fn\":\"avg\",\"field\":\"boss.salary\"}],"
    # "\"orderBy\":[{\"field\":\"dept.budget\"}],"
    # "\"select\":[\"name\",\"dept.name\"]}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#eq(path, _)) { assert path == ["dept", "name"] };
        case _ { assert false };
      };
      assert q.groupBy == [["dept", "name"]];
      assert q.aggregate[0].field == ?["boss", "salary"];
      assert q.orderBy[0].field == ["dept", "budget"];
      switch (q.select) {
        case (?ps) { assert ps == [["name"], ["dept", "name"]] };
        case null { assert false };
      };
    };
  };
});

test("aggregate.as with a dot is rejected (would be unreachable)", func () {
  let json = "{\"start\":\"x\",\"aggregate\":[{\"fn\":\"count\",\"as\":\"a.b\"}]}";
  switch (okQuery(json)) {
    case (#err _) { assert true };
    case (#ok _)  { assert false };
  };
});

test("empty path segments are rejected", func () {
  for (bad in (["a..b", ".a", "b.", "."] : [Text]).values()) {
    let json = "{\"start\":\"x\",\"select\":[\"" # bad # "\"]}";
    switch (okQuery(json)) {
      case (#err _) { assert true };
      case (#ok _)  { assert false };
    };
  };
});

test("float literals parse into #float (eq + in)", func () {
  // Use exact-binary fractions so JSON->Float and source-literal Float
  // land on identical bits — `0.42` would round-trip differently.
  let eqJson = "{\"start\":\"trip\",\"where\":{\"gt\":{\"field\":\"ratio\",\"value\":0.5}}}";
  switch (okQuery(eqJson)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#gt(path, #float v)) { assert path == ["ratio"]; assert v == 0.5 };
        case _ { assert false };
      };
    };
  };
  let inJson = "{\"start\":\"trip\",\"where\":"
    # "{\"in\":{\"field\":\"factor\",\"value\":[0.25,0.5,1.0]}}}";
  switch (okQuery(inJson)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#in_(_, vs)) {
          assert vs.size() == 3;
          assert vs[0] == #float(0.25);
          assert vs[1] == #float(0.5);
          assert vs[2] == #float(1.0);
        };
        case _ { assert false };
      };
    };
  };
});

test("negative floats survive the parser (not mistaken for integers)", func () {
  // -3.5 is exactly representable in IEEE-754, so == is safe.
  let json = "{\"start\":\"trip\",\"where\":{\"lt\":{\"field\":\"temp\",\"value\":-3.5}}}";
  switch (okQuery(json)) {
    case (#err _) { assert false };
    case (#ok q)  {
      switch (q.where_) {
        case (?#lt(_, #float v)) { assert v == -3.5 };
        case _ { assert false };
      };
    };
  };
});
