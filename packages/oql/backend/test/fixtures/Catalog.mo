/// Heavier replica fixture: a small e-commerce catalog. Three entities,
/// one with a hidden field, edges between orders and both customers and
/// products. Seeded with ~30 rows so OQL has something to filter/sort/page
/// over. The companion replica test instantiates this and drives it with
/// real JSON queries.

import Map     "mo:core/Map";
import Nat     "mo:core/Nat";
import OQL     "../../src";
import Expose  "../../src/Expose";

actor class Catalog() = self {

  // ── Domain types ─────────────────────────────────────────────────────

  type Customer = {
    id           : Nat;
    name         : Text;
    country      : Text;
    age          : Nat;
    vip          : Bool;
    passwordHash : Text;  // exposed as #hidden — must never leak
  };

  type Product = {
    id    : Nat;
    sku   : Text;
    name  : Text;
    price : Nat;   // in cents
  };

  type Order = {
    id         : Nat;
    customerId : Nat;
    productId  : Nat;
    quantity   : Nat;
    paid       : Bool;
  };

  // ── Storage ──────────────────────────────────────────────────────────

  let customers : Map.Map<Nat, Customer> = Map.empty();
  let products  : Map.Map<Nat, Product>  = Map.empty();
  let orders    : Map.Map<Nat, Order>    = Map.empty();

  // ── Seed data ────────────────────────────────────────────────────────

  func seedOrder(id : Nat, customerId : Nat, productId : Nat, quantity : Nat, paid : Bool) =
    orders.add(id, { id; customerId; productId; quantity; paid });

  do {
    // 6 customers across 4 countries, mix of vip and age.
    customers.add(1, { id = 1; name = "alice";   country = "DE"; age = 34; vip = true;  passwordHash = "h1" });
    customers.add(2, { id = 2; name = "bob";     country = "UK"; age = 22; vip = false; passwordHash = "h2" });
    customers.add(3, { id = 3; name = "charlie"; country = "DE"; age = 41; vip = false; passwordHash = "h3" });
    customers.add(4, { id = 4; name = "dora";    country = "FR"; age = 29; vip = true;  passwordHash = "h4" });
    customers.add(5, { id = 5; name = "eve";     country = "DE"; age = 19; vip = false; passwordHash = "h5" });
    customers.add(6, { id = 6; name = "frank";   country = "US"; age = 55; vip = true;  passwordHash = "h6" });

    // 4 products at varied price points.
    products.add(101, { id = 101; sku = "SKU-A"; name = "espresso machine"; price = 49900 });
    products.add(102, { id = 102; sku = "SKU-B"; name = "burr grinder";     price = 19900 });
    products.add(103, { id = 103; sku = "SKU-C"; name = "scale";            price = 5900  });
    products.add(104, { id = 104; sku = "SKU-D"; name = "cleaner tablets";  price = 1200  });

    // 12 orders spanning every combination we want to filter on.
    seedOrder( 1, 1, 101, 1, true);
    seedOrder( 2, 1, 103, 2, true);
    seedOrder( 3, 2, 104, 5, false);
    seedOrder( 4, 3, 101, 1, true);
    seedOrder( 5, 3, 102, 1, false);
    seedOrder( 6, 4, 101, 1, true);
    seedOrder( 7, 4, 104, 3, true);
    seedOrder( 8, 5, 102, 1, false);
    seedOrder( 9, 5, 103, 1, true);
    seedOrder(10, 6, 101, 2, true);
    seedOrder(11, 6, 102, 1, true);
    seedOrder(12, 6, 104, 4, false);
  };

  // ── OQL schema overlay ───────────────────────────────────────────────

  include Expose({
    entities = [

      customers.toEntity("customer", "Customer", "id")
        .hidden("passwordHash")
        .build(),

      products.toEntity("product", "Product", "id").build(),

      orders.toEntity("order", "Order", "id")
        .edge("customerId", "customer")
        .edge("productId",  "product")
        .build(),

    ];
  });

};
