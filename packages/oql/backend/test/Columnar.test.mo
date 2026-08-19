/// Differential oracle for the multi-column store: the maintained per-column
/// `sumOf` and the live-row `count` must agree with a brute-force scan over
/// `getRow`, across the full split state — rows in segments, rows in the buffer,
/// null cells, and tombstones created both at flush time (a row deleted while
/// buffered, then flushed) and after flush (deleting an already-flushed row).
///
/// Integer/nat/bool sums are compared exactly; a float sum is maintained by
/// adding at flush and subtracting at delete, which is not bit-identical to
/// summing only the live values, so it is compared within a small tolerance.
/// Runs under PocketIC because it uses a Region.
import { test } "mo:test/async";
import Columnar "../src/columnar/Columnar";
import Cell "../src/columnar/Cell";
import Nat64 "mo:core/Nat64";
import Int64 "mo:core/Int64";
import Int "mo:core/Int";
import Float "mo:core/Float";
import Nat "mo:core/Nat";

actor {

  // Row shape: [ #nat, #int, #float, #bool ]. Columns 0 and 2 carry some nulls.
  func mkRow(i : Nat) : [?Cell.Cell] {
    [
      if (i % 4 == 0) null else ?#nat(Nat64.fromNat(i * 10)),
      ?#int(Int64.fromIntWrap(-i)),
      if (i % 5 == 0) null else ?#float(Int.toFloat(i)),
      ?#bool(i % 2 == 0),
    ];
  };

  func sumClose(a : Cell.Sum, b : Cell.Sum) : Bool {
    switch (a, b) {
      case (#int x, #int y) x == y;
      case (#float x, #float y) Float.abs(x - y) < 1e-9 * (1.0 + Float.abs(x));
      case _ false;
    };
  };

  // Brute-force per-column sum + live count via the public scan.
  func oracle(s : Columnar.State) : ([Cell.Sum], Nat) {
    let C = Columnar.columns(s);
    let acc = [var Cell.zeroSum(s.cols[0]), Cell.zeroSum(s.cols[1]), Cell.zeroSum(s.cols[2]), Cell.zeroSum(s.cols[3])];
    var cnt = 0;
    for ((_, row) in Columnar.scan(s)) {
      cnt += 1;
      var c = 0;
      while (c < C) {
        switch (row[c]) { case (?v) acc[c] := Cell.addSum(acc[c], v); case null {} };
        c += 1;
      };
    };
    ([acc[0], acc[1], acc[2], acc[3]], cnt);
  };

  public func runTests() : async () {
    await test("multi-column sum/count agree with a scan across the split state", func() : async () {
      let s = Columnar.new([#nat, #int, #float, #bool], 0, 0); // manual flush: the test drives the split state

      var i = 0;
      while (i < 12) { ignore Columnar.append(s, mkRow(i)); i += 1 }; // rows 0..11
      Columnar.flush(s);
      assert s.watermark == 12;

      while (i < 18) { ignore Columnar.append(s, mkRow(i)); i += 1 }; // buffer rows 12..17
      Columnar.delete(s, 3); // flushed
      Columnar.delete(s, 8); // flushed
      Columnar.delete(s, 14); // buffered → tombstoned at next flush
      Columnar.flush(s);
      assert s.watermark == 18;

      while (i < 21) { ignore Columnar.append(s, mkRow(i)); i += 1 }; // buffer rows 18..20
      Columnar.delete(s, 15); // now flushed
      Columnar.delete(s, 19); // buffered

      let (oSums, oCnt) = oracle(s);
      assert Columnar.count(s) == oCnt;
      var c = 0;
      while (c < 4) {
        assert sumClose(Columnar.sumOf(s, c), oSums[c]);
        c += 1;
      };

      // deleted ids are 3, 8, 14, 15, 19 → 21 total − 5 = 16 live rows
      assert oCnt == 16;

      // spot checks across both stores + tombstones + null cells
      assert Columnar.getCell(s, 0, 0) == null;        // row 0, col 0: i%4==0 → null cell
      assert Columnar.getCell(s, 1, 0) == ?#nat(10);   // row 1, col 0: live
      assert Columnar.getCell(s, 20, 3) == ?#bool(true); // row 20, col 3: buffered, even
      assert Columnar.getRow(s, 14) == null;           // deleted-while-buffered, then flushed
      assert Columnar.getRow(s, 15) == null;           // deleted after flush
      assert Columnar.getRow(s, 19) == null;           // deleted while buffered
      switch (Columnar.getRow(s, 10)) {                // live flushed row
        case (?row) { assert row[1] == ?#int(-10) };
        case null { assert false };
      };
    });

    await test("byte-budget flush seals segments by size, and reads resolve across them", func() : async () {
      // A #nat cell is 8 bytes; the text is a fixed 12 chars ⟹ 20 bytes/row.
      // Row trigger off; byte budget 100 ⟹ a flush every 5th row.
      let txt = "cccccccccccc"; // 12 chars
      func row(i : Nat) : [?Cell.Cell] = [?#nat(Nat64.fromNat(i)), ?#text(txt)];
      let s = Columnar.new([#nat, #text], 0, 100);

      var i = 0;
      while (i < 5) { ignore Columnar.append(s, row(i)); i += 1 }; // 5th append hits 100 bytes → flush
      assert s.watermark == 5;
      assert s.bufferBytes == 0;

      while (i < 12) { ignore Columnar.append(s, row(i)); i += 1 }; // flushes again at 10; 10,11 buffered
      assert s.watermark == 10;      // two byte-budget flushes, no row-count trigger
      assert Columnar.count(s) == 12; // 10 flushed + 2 buffered

      // segmentOf now spans two segments; binary search must land each row in
      // the right one (spot-check the boundaries and a buffered row).
      var k = 0;
      while (k < 12) {
        switch (Columnar.getRow(s, k)) {
          case (?r) { assert r[0] == ?#nat(Nat64.fromNat(k)) };
          case null { assert false };
        };
        k += 1;
      };
    });
  };
};
