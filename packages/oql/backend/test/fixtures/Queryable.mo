/// Fixture actor class for the replica/PocketIC test. The user-facing
/// example in `example/main.mo` is an anonymous top-level actor (correct
/// for `mops build`), but replica tests need a *class* they can
/// instantiate via `await Queryable()`.

import Map     "mo:core/Map";
import Nat     "mo:core/Nat";
import OQL     "../../src";
import Expose  "../../src/Expose";

actor class Queryable() = self {

  type Customer = { id : Nat; name : Text; country : Text };

  /// Hard-seeded so the test has predictable rows without calling
  /// `placeOrder`-style helpers first.
  let customers : Map.Map<Nat, Customer> = Map.empty();

  // Seed at init.
  do {
    customers.add(1, { id = 1; name = "alice";   country = "DE" });
    customers.add(2, { id = 2; name = "bob";     country = "UK" });
    customers.add(3, { id = 3; name = "charlie"; country = "DE" });
  };

  include Expose({
    entities = [
      customers.toEntity("customer", "Customer", "id").build(),
    ];
  });

};
