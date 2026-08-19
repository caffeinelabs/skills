/// Fixture actor class exposing columnar `Table`s through the `Expose` mixin.
///
/// The tables are deliberately EMPTY when `include Expose(...)` runs, and rows
/// arrive afterwards over `seed()`. That order is the point: the mixin builds its
/// registry while the actor initialises, which is the state a canister is in the
/// first time it is installed. An entity whose schema were derived from a stored
/// row would have no fields here — and so no declared edges — for the whole life
/// of the installation.
///
/// Every other mixin fixture populates its data before the `include`, so none of
/// them can catch that.

import OQL      "../../src";
import Table    "../../src/Table";
import Expose   "../../src/Expose";
// moc 1.11.2: implicits & contextual-dot calls no longer resolve through re-exports — import leaves directly.
import _Entity  "../../src/Entity";

actor class TableExposed() = self {

  let customers = Table.new([("region", #nat), ("name", #text)], [("region", #hash)]);
  let orders = Table.new(
    [("customerId", #nat), ("amount", #nat)],
    [("customerId", #hash)]);

  func custRow((region, name) : (Nat, Text)) : [(Text, OQL.Value)] =
    [("region", #nat region), ("name", #text name)];
  func ordRow((cid, amount) : (Nat, Nat)) : [(Text, OQL.Value)] =
    [("customerId", #nat cid), ("amount", #nat amount)];

  /// Customers 0..2 in regions 0, 1, 0; two orders per customer. Called after
  /// initialisation, so the registry was built over empty tables.
  public func seed() : async () {
    ignore customers.append<(Nat, Text)>((0, "alice"), custRow);
    ignore customers.append<(Nat, Text)>((1, "bob"), custRow);
    ignore customers.append<(Nat, Text)>((0, "carol"), custRow);
    var k = 0;
    while (k < 3) {
      ignore orders.append<(Nat, Nat)>((k, 10 + k), ordRow);
      ignore orders.append<(Nat, Nat)>((k, 20 + k), ordRow);
      k += 1;
    };
    customers.flush();
    orders.flush();
  };

  include Expose({
    entities = [
      customers.entityWith("customer", "Customer", "id").public_().build(),
      orders.entityWith("order", "Order", "id").edge("customerId", "customer").public_().build(),
    ];
  });

};
