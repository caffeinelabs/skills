---
name: extension-stripe
description: >-
  Payment support based on Stripe, supporting credit cards and debit cards.
  Checkout and session status use HTTP outcalls. For inbound Stripe webhooks
  (POST to the canister), also load extension-http-endpoints.
version: 1.0.2
compatibility:
  mops:
    caffeineai-stripe: "~1.0.0"
    caffeineai-http-outcalls: "~0.1.3"
    caffeineai-authorization: "~1.0.1"
caffeineai-subscription: [none]
---

# Stripe Payment Integration
Stripe payment extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds Stripe payment support using HTTP outcalls. The `MixinStripe` mixin provides configuration, checkout session creation, payment status checks, and the HTTP outcall `transform` callback. The frontend handles checkout flow and payment result pages.

Inbound Stripe webhooks (an external `POST` to the canister) are not covered here — use [`extension-http-endpoints`](../extension-http-endpoints/SKILL.md) for the `http_request` / `http_request_update` handlers, then verify Stripe signatures in the update path.

Prerequisite: You must follow [extension-authorization](../extension-authorization/SKILL.md) first, as this integration depends on it.

# Backend

## Module API

The prefabricated module `mo:caffeineai-stripe/stripe.mo` provides low-level Stripe HTTP helpers. Do not modify it.

```mo:caffeineai-stripe/stripe.mo
import OutCall "mo:caffeineai-http-outcalls/outcall";

module {
  public type StripeConfiguration = {
    secretKey : Text;
    allowedCountries : [Text];
  };

  public type StripeState = {
    var configuration : ?StripeConfiguration;
  };

  public func initState() : StripeState;

  public type ShoppingItem = {
    currency : Text;
    productName : Text;
    productDescription : Text;
    priceInCents : Nat;
    quantity : Nat;
  };

  public func createCheckoutSession(configuration : StripeConfiguration, caller : Principal, items : [ShoppingItem], successUrl : Text, cancelUrl : Text, transform : OutCall.Transform) : async Text;

  public type StripeSessionStatus = {
    #failed : { error : Text };
    #completed : { response : Text; userPrincipal : ?Text };
  };

  public func getSessionStatus(configuration : StripeConfiguration, sessionId : Text, transform : OutCall.Transform) : async StripeSessionStatus;
};
```

## Setup in main.mo

`include MixinStripe(accessControlState, stripeState)` MUST be placed in `main.mo`, not in a custom mixin file. The mixin provides these public endpoints automatically:

- `isStripeConfigured()`
- `setStripeConfiguration(config)`
- `createCheckoutSession(items, successUrl, cancelUrl)`
- `getStripeSessionStatus(sessionId)`
- `transform(input)` — required for HTTP outcall response transformation

Do NOT redeclare any of these functions. They are provided exclusively by `MixinStripe`.

```motoko filepath=src/backend/main.mo
import Stripe "mo:caffeineai-stripe/stripe";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import MixinStripe "mo:caffeineai-stripe/MixinStripe";
import Map "mo:core/Map";
import Iter "mo:core/Iter";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";

actor {
  // Include authorization
  let accessControlState : AccessControl.AccessControlState;
  include MixinAuthorization(accessControlState, null);
  let stripeState : Stripe.StripeState;
  include MixinStripe(accessControlState, stripeState);

  public type Product = {
    id : Text;
    // add custom fields
  };

  let products : Map.Map<Text, Product>;

  public query func getProducts() : async [Product] {
    products.values().toArray();
  };

  public shared ({ caller }) func addProduct(product : Product) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can add products");
    };
    products.add(product.id, product);
  };

  public shared ({ caller }) func updateProduct(product : Product) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can update products");
    };
    products.add(product.id, product);
  };

  public shared ({ caller }) func deleteProduct(productId : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can delete products");
    };
    products.remove(productId);
  };

  // Add more data and functions as needed
};
```

The migration chain head:

```motoko filepath=src/backend/migrations/00000000_000000.mo
import Map "mo:core/Map";
import AccessControl "mo:caffeineai-authorization/access-control";

module {
  type Product = {
    id : Text;
  };

  type StripeConfiguration = {
    secretKey : Text;
    allowedCountries : [Text];
  };

  type StripeState = {
    var configuration : ?StripeConfiguration;
  };

  type NewActor = {
    accessControlState : AccessControl.AccessControlState;
    products : Map.Map<Text, Product>;
    stripeState : StripeState;
  };

  public func migration(_old : {}) : NewActor {
    {
      accessControlState = AccessControl.initState();
      products = Map.empty<Text, Product>();
      stripeState = { var configuration = null };
    };
  };
};
```

# Frontend

For Stripe payment integration:

Usage:

1. Implement a PaymentSetup component with:
    * Use `isStripeConfigured()` and `setStripeConfiguration()`
    * Checks whether Stripe payment is configured.
    * If not, opens an admin panel and asks the user to initialze Stripe with `StripeConfiguration`.
      - Stripe secret key
      - List of allowed countries, notation ["US", "CA", "GB"] etc., see the Stripe documentation.
    * Do not show the payment setup when it has already been configured!

2. Implement a checkout hook:
    * Note that JSON parsing of backend `createCheckoutSession` result is needed.
    * Validate that the parsed session includes a non-empty `url`. If missing, throw an error and do not redirect.
    
    ```
    import { useMutation } from '@tanstack/react-query';
    import { useActor } from '@caffeineai/core-infrastructure';
    import { ShoppingItem } from '../backend';

    export type CheckoutSession = {
        id: string;
        url: string;
    };

    export function useCreateCheckoutSession() {
        const { actor } = useActor();

        return useMutation({
            mutationFn: async (items: ShoppingItem[]): Promise<CheckoutSession> => {
                if (!actor) throw new Error('Actor not available');
                const baseUrl = `${window.location.protocol}//${window.location.host}`;
                const successUrl = `${baseUrl}/payment-success`;
                const cancelUrl = `${baseUrl}/payment-failure`;
                const result = await actor.createCheckoutSession(items, successUrl, cancelUrl);
                // JSON parsing is important!
                const session = JSON.parse(result) as CheckoutSession;
                if (!session?.url) {
                    throw new Error('Stripe session missing url');
                }
                return session;
            }
        });
    }
    ```

3. Implement a Payment component with:
    * `useCreateCheckoutSession()`
    * Pass `ShoppingItem[]` as input.
    * Anaylze the `CheckoutSession` result.
    * Redirect webpage to url in `CheckoutSession`: This allows the user to complete the payment.
    * Do NOT use router navigation for the Stripe URL. Use `window.location.href`.
    * Never navigate to `/undefined`; if `session.url` is missing, show an error and stop.

    ```
    const session = await createCheckoutSession.mutateAsync(shoppingItems);
    if (!session?.url) throw new Error('Stripe session missing url');
    window.location.href = session.url;
    ```

4. Implement a PaymentSuccess and PaymentFailure component to handle payment success or failure, respectively.

5. Route two specific paths to the payment status components:
   * Path "/payment-success" to PaymentSuccess.
   * Path "/payment-failure" to PaymentFailure.
   You need to use @tanstack router.

6. The admin view offers a menu to configure Stripe. If not yet configured, it asks the admin to configure Stripe on login.

Side note: Make sure that product images are properly rendered and resized inside the product canvas.
