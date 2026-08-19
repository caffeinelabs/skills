/// Building an index over a bulk-loaded table: `Table.addIndex` + `buildStep`.
///
/// The oracle is a TWIN table with the same rows appended row-at-a-time and the
/// index declared at construction — the maintenance path that is already tested.
/// After the build completes, every point lookup on the built index must yield
/// exactly the twin's positions. Until it completes, the pending decl must be
/// invisible (`kindOf` null), so the planner scans and answers stay correct
/// mid-build — the no-partial-serve discipline `IndexedMap.addIndex` set.
///
/// Convergence is pinned from both sides of the cursor: a row deleted ahead of
/// the walk is skipped, one deleted behind it loses its posting through
/// `onChange`, and a row appended mid-build is served once the build is done.
/// Runs under PocketIC because it uses a Region.
import { test } "mo:test/async";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import Region "mo:core/Region";
import Cell "../src/columnar/Cell";
import Image "../src/columnar/Image";
import SecondaryIndex "../src/SecondaryIndex";
import Table "../src/Table";
import Types "../src/Types";

actor {

  let N = 10_000;
  let COLS : [Table.Column] = [("acct", #nat), ("amount", #nat)];

  // acct spreads over 100 values, so each posting holds ~N/100 positions; the
  // nulls exercise indexing under #null_.
  func cellOf(r : Nat, c : Nat) : ?Cell.Cell =
    if (c == 0) { if (r % 11 == 0) null else ?#nat(Nat64.fromNat(r % 100)) }
    else ?#nat(Nat64.fromNat(r * 7 % 1_000));

  func rowOf(r : Nat) : [(Text, Types.Value)] = [
    ("acct", switch (cellOf(r, 0)) { case (?#nat n) #nat(Nat64.toNat(n)); case _ #null_ }),
    ("amount", switch (cellOf(r, 1)) { case (?#nat n) #nat(Nat64.toNat(n)); case _ #null_ }),
  ];

  // Identity lineariser: tests feed the row shape directly.
  func asRow(row : [(Text, Types.Value)]) : [(Text, Types.Value)] = row;

  func imageLoaded() : Table.Table {
    let t = Table.new(COLS, []);
    let scratch = Region.new();
    ignore Table.loadSegment(t, Image.build(scratch, [#nat, #nat], N, cellOf));
    t;
  };

  func upfrontTwin() : Table.Table {
    let t = Table.new(COLS, [("acct", #hash)]);
    var r = 0;
    while (r < N) { ignore Table.append(t, rowOf(r), asRow); r += 1 };
    Table.flush(t);
    t;
  };

  func points(t : Table.Table, col : Text, v : Types.Value) : [Nat] {
    let out = Array.fromIter<Nat>(SecondaryIndex.point<Nat>(t.ix, col, v));
    Array.sort<Nat>(out, Nat.compare);
  };

  func drive(t : Table.Table, st : Table.IndexBuild) {
    // A deliberately small budget, so completion takes many steps and the
    // resume-at-cursor path is what is actually exercised.
    while (not Table.buildStep(t, st, 997)) {};
  };

  public func runTests() : async () {
    await test("a built index serves exactly what an upfront index serves", func() : async () {
      let a = imageLoaded();
      let b = upfrontTwin();
      let st = Table.addIndex(a, "acct", #hash);

      // Pending: invisible to the planner, so no partial serve is possible.
      assert SecondaryIndex.kindOf(a.ix, "acct") == null;
      assert not Table.buildStep(a, st, 100);   // one small step — still pending
      assert SecondaryIndex.kindOf(a.ix, "acct") == null;

      drive(a, st);
      assert SecondaryIndex.kindOf(a.ix, "acct") == ?#hash;
      var v = 0;
      while (v < 100) {
        assert points(a, "acct", #nat v) == points(b, "acct", #nat v);
        v += 1;
      };
      assert points(a, "acct", #null_) == points(b, "acct", #null_);
      assert Table.buildStep(a, st, 1);   // done stays done
    });

    await test("deletes on both sides of the cursor converge", func() : async () {
      let t = imageLoaded();
      let st = Table.addIndex(t, "acct", #hash);
      ignore Table.buildStep(t, st, N / 2);   // cursor at N/2
      let behind = 1;      // acct 1, already walked
      let ahead = N - 3;   // acct (N-3) % 100, not yet walked
      Table.delete(t, behind);
      Table.delete(t, ahead);
      drive(t, st);
      for (pos in [behind, ahead].values()) {
        let acct = #nat(pos % 100);
        assert Array.find<Nat>(points(t, "acct", acct), func p = p == pos) == null;
      };
    });

    await test("rows appended mid-build are served once ready", func() : async () {
      let t = imageLoaded();
      let st = Table.addIndex(t, "acct", #hash);
      ignore Table.buildStep(t, st, N / 2);
      let pos = Table.append(t, [("acct", #nat 777), ("amount", #nat 1)], asRow);
      drive(t, st);
      assert Array.find<Nat>(points(t, "acct", #nat 777), func p = p == pos) != null;
    });

    await test("clustered nat and text keys build identically to an upfront index", func() : async () {
      // Two paths the other tests never touch, in one differential. Runs of
      // consecutive EQUAL keys are what the segment-wise walk's memoized writer
      // serves from its memo — `acct` above changes key every row, so the memo
      // never hits there. And a `#text` column exercises `colRun`'s
      // variable-width branch (offsets + packed bytes), whose mis-slice would
      // mis-key every posting of a post-load text index. Nulls and the empty
      // string ride along: both are real, distinct index keys.
      let COLS2 : [Table.Column] = [("day", #nat), ("name", #text)];
      func cell2(r : Nat, c : Nat) : ?Cell.Cell =
        if (c == 0) ?#nat(Nat64.fromNat(r / 1_000))
        else if (r % 13 == 0) null
        else if (r % 17 == 0) ?#text("")
        else ?#text("u" # Nat.toText(r / 500));
      func row2(r : Nat) : [(Text, Types.Value)] = [
        ("day", #nat(r / 1_000)),
        ("name",
          if (r % 13 == 0) #null_
          else if (r % 17 == 0) #text("")
          else #text("u" # Nat.toText(r / 500))),
      ];
      let a = Table.new(COLS2, []);
      let scratch = Region.new();
      ignore Table.loadSegment(a, Image.build(scratch, [#nat, #text], N, cell2));
      let b = Table.new(COLS2, [("day", #hash), ("name", #hash)]);
      var r = 0;
      while (r < N) { ignore Table.append(b, row2(r), asRow); r += 1 };
      Table.flush(b);
      drive(a, Table.addIndex(a, "day", #hash));
      drive(a, Table.addIndex(a, "name", #hash));
      var d = 0;
      while (d < N / 1_000) { assert points(a, "day", #nat d) == points(b, "day", #nat d); d += 1 };
      var u = 0;
      while (u < N / 500) {
        let k = #text("u" # Nat.toText(u));
        assert points(a, "name", k) == points(b, "name", k);
        u += 1;
      };
      assert points(a, "name", #null_) == points(b, "name", #null_);
      assert points(a, "name", #text "") == points(b, "name", #text "");
    });

    await test("a composite build serves its prefix range", func() : async () {
      let t = imageLoaded();
      let st = Table.addComposite(t, ["acct", "amount"], #ordered);
      assert SecondaryIndex.readyComposites(t.ix).size() == 0;
      drive(t, st);
      assert SecondaryIndex.readyComposites(t.ix) == [["acct", "amount"]];
      // acct = 5, any amount: exactly the rows a scan finds.
      let got = Array.fromIter<Nat>(SecondaryIndex.compositeRange<Nat>(
        t.ix, ["acct", "amount"], [#nat 5], null, null, #asc));
      var want = 0;
      var r = 0;
      while (r < N) { if (r % 11 != 0 and r % 100 == 5) want += 1; r += 1 };
      assert got.size() == want;
    });
  };
};
