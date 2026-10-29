---
name: extension-email-raw
description: Send an email with multiple to, cc and bcc addresses.
version: 0.3.0
compatibility:
  mops:
    caffeineai-email: "~0.5.0"
caffeineai-subscription: [plus, pro]
---

# Email — Raw Multi-Recipient
Raw multi-recipient email extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds support for sending emails with multiple `to`, `cc`, and `bcc` recipients. Not suitable for bulk service emails (recipients see each other).

# Backend

## This extension is for sending an email with support for multiple `to`, `cc` and `bcc` addresses.

- This should NOT be used for sending service emails to multiple users because each recipient will see all the other recipients listed which would typically be a breach of user privacy.

### For sending an email

- This extension depends on the [extension-email](../extension-email/SKILL.md) for sending emails.
- Use the sendRawEmail function. 
- It returns a SendResult which is #ok if the email is sent successfully otherwise #err(error) with the error text. 
- There can be a maximum of 50 recipients in total
- Each recipient receives the same email

```mo:caffeineai-email/emailClient.mo
module {
  public type SendResult = {
    #ok;
    #err : Text;
  };

  public func sendRawEmail(
    fromUsername : Text,
    to : [Text],
    cc : [Text],
    bcc : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult;
};
```

### Example usage for sending an email reminder to meeting attendees.

```motoko filepath=src/backend/main.mo
import Runtime "mo:core/Runtime";
import EmailClient "mo:caffeineai-email/emailClient";

actor {
  public func sendMeetingReminder(
    meetingSubject : Text,
    meetingTime : Text,
    confirmedAttendeeEmails : [Text],
    tentativeAttendeeEmails : [Text],
  ) : async () {
    let result = await EmailClient.sendRawEmail(
      "no-reply",
      confirmedAttendeeEmails,
      tentativeAttendeeEmails,
      [],
      meetingSubject,
      "Reminder the meeting will start at " # meetingTime,
    );

    switch (result) {
      case (#ok) {};
      case (#err(error)) {
        Runtime.trap("Failed to send meeting reminder email: " # error);
      };
    };
  };
};
```

## Upgrading from the previous version

An app built with `caffeineai-email` 0.4.x re-pins with `mops add caffeineai-email@0.5.0`. `sendRawEmail` keeps its signature. 0.5.0 compiles with `ic` 5.0.0, where 0.4.x fails. In an app that pins `ic` 5.0.0, its gateway calls use outcall pricing version 2; on `ic` 4.2.0 they keep version 1.

An app built with `caffeineai-email` 0.3.x re-pins with `mops add caffeineai-email@0.4.0`. `sendRawEmail` keeps its signature. Every send now goes through the mail gateway with the settings the platform injects on every deploy (`INTEGRATIONS_GATEWAY_URL` / `INTEGRATIONS_GATEWAY_API_KEY`); the transport canister and `INTEGRATIONS_CANISTER_ID` are no longer used, and a send without those settings returns `#err` instead of falling back.

An app built with `caffeineai-email` 0.2.x re-pins with `mops add caffeineai-email@0.3.0`. `sendRawEmail` keeps their signatures; every send now carries an idempotency key, so a retried outcall is sent and charged once. Apps that use verification or marketing email follow the upgrade sections of those skills.
