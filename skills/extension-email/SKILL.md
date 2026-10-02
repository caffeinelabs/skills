---
name: extension-email
description: Support for sending service/transactional emails. Don't use this for sending marketing emails or verification emails.
version: 0.3.0
compatibility:
  mops:
    caffeineai-email: "~0.3.0"
caffeineai-subscription: [plus, pro]
---

# Email — Service/Transactional
Service/transactional email extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds support for sending service and transactional emails from the backend canister. Use `sendServiceEmail` for order confirmations, notifications, and similar one-off emails.

# Backend

This component is for sending service/transactional emails. 

There is the prefabricated module `mo:caffeineai-email/emailClient.mo` which cannot be modified.

- Use the sendServiceEmail function. 
- Each recipient is sent an individual email
- It returns a SendResult which is #ok if the email is sent successfully otherwise #err(error) with the error text. 

```mo:caffeineai-email/emailClient.mo
module {
  public type SendResult = {
    #ok;
    #err : Text;
  };

  public func sendServiceEmail(
    fromUsername : Text,
    recipients : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult;
};
```

Usage for `sendServiceEmail`:

```motoko filepath=src/backend/main.mo
import Runtime "mo:core/Runtime";
import EmailClient "mo:caffeineai-email/emailClient";

actor {
  public func sendOrderConfirmationEmail(recipientEmailAddress : Text, username : Text, orderReference : Text) : async () {
    let result = await EmailClient.sendServiceEmail(
      "no-reply",
      [recipientEmailAddress],
      "Order " # orderReference # " confirmed",
      "Hello " # username # ",\nYour order " # orderReference # " has been confirmed. Your items will ship tomorrow.",
    );
    switch (result) {
      case (#ok) {};
      case (#err(error)) {
        Runtime.trap("Failed to send order confirmation email: " # error);
      };
    };
  };
};
```

## Upgrading from the previous version

An app built with `caffeineai-email` 0.2.x re-pins with `mops add caffeineai-email@0.3.0`. `sendServiceEmail` and `sendRawEmail` keep their signatures; every send now carries an idempotency key, so a retried outcall is sent and charged once. Apps that use verification or marketing email follow the upgrade sections of those skills.
