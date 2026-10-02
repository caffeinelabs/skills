---
name: extension-email-marketing
description: Send personalised marketing emails to subscribers with an unsubscribe link.
version: 0.2.0
compatibility:
  mops:
    caffeineai-email-marketing: "~0.2.0"
    caffeineai-email-verification: "~0.2.0"
    caffeineai-email: "~0.3.0"
    caffeineai-authorization: "~1.0.1"
  npm:
    "@caffeineai/email-marketing": "~0.2.0"
caffeineai-subscription: [plus, pro]
---

# Email — Marketing
Marketing email extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds direct marketing email support with subscriber management, topic-based subscriptions, and unsubscribe links that land on the app's own frontend. The backend mints one unsubscribe token per subscriber and topic (`unsubscribeTokens`) and handles it through `MixinEmailUnsubscribe`; the frontend renders the `/unsubscribe` page, where the recipient clicks a button to unsubscribe. Requires email verification before users can receive marketing emails.

## Required Setup Checklist

All six steps are mandatory.

1. **mops dependencies** — `mops add caffeineai-email-marketing`, `mops add caffeineai-email-verification` and `mops add caffeineai-authorization`.
2. **Stable state fields** — `emailSubscribers : EmailSubscribers.State` and `unsubscribeTokens : UnsubscribeTokens.State` (plus the verification states `verifiedEmails` and `verificationTokens`), initialised in the migration chain head.
3. **Mixin invocations** — `include MixinEmailUnsubscribe(emailSubscribers, unsubscribeTokens)` and `include MixinEmailVerification(verifiedEmails, verificationTokens)` in `main.mo`.
4. **Sending** — `EmailMarketing.sendMarketingEmail(emailSubscribers, verifiedEmails, unsubscribeTokens, topicId, fromUsername, subject, htmlBody, personalise)` sends to every verified subscriber of the topic; the app never assembles the recipient list. `sendMarketingEmailTo` takes explicit addresses and sends to those of them that are verified subscribers of the topic.
5. **Unsubscribe link** — the body should contain `{{UNSUBSCRIBE_URL}}`; when it is missing an unsubscribe line is appended. Every copy also carries a `List-Unsubscribe` header pointing at the same page.
6. **Frontend npm package and route** — `@caffeineai/email-marketing` installed, and a public route `/unsubscribe` (reachable without signing in) that renders a button calling `confirm()`.

CRITICAL: the unsubscribe link is `https://<app domain>/unsubscribe?token=…`. Without the frontend route the recipient lands on a missing page and cannot unsubscribe, which is a compliance failure.

# Backend

## This component is for sending direct marketing emails and managing subscribers to marketing topics.

- Users MUST have verified their email address AND MUST be subscribed to a marketing topic before they can receive marketing emails on that topic
- Marketing emails MUST contain an unsubscribe link which will unsubscribe the user from the given topic
- This component depends on the [extension-email-verification](../extension-email-verification/SKILL.md) for verifying email addresses, be sure to check that too.

### To subscribe users to marketing topics and manage lists of subscribers

- Use the prefabricated module `mo:caffeineai-email-marketing/subscribers.mo` which cannot be modified.
- Marketing email subscribers MUST be handled solely through this subscribers module
- Do NOT also store a subscribed status against user profiles
- CRITICAL: a marketing mail goes only to verified subscribers of its topic, added through `EmailSubscribers.add`. `sendMarketingEmail` reads them itself and `sendMarketingEmailTo` drops every other address, because the unsubscribe link of an address outside the topic is rejected by `_caffeineEmailUnsubscribe`, which is a compliance failure.

```mo:caffeineai-email-marketing/subscribers.mo
module {
  public type State = {
    var topics : Map.Map<Nat, TopicRecord>;
    var topicsByName : Map.Map<Text, Nat>;
  };

  // Add a new topic by name or get an existing topic if it already exists. Returns the topic ID.
  public func addTopic(state : State, name : Text) : Nat;

  // Rename a topic. Returns false if a topic with the new name already exists or the topic ID does not exist.
  public func renameTopic(state : State, topicId : Nat, newName : Text) : Bool;

  // Remove a topic. Also removes all subscribers from that topic; their unsubscribe links stop working.
  public func removeTopic(state : State, tokens : UnsubscribeTokens.State, topicId : Nat);

  // List all topics (id, name).
  public func listTopics(state : State) : [Topic];

  // Get a topic ID by name
  public func getTopicId(state : State, name : Text) : ?Nat;

  // Get a topic name by ID
  public func getTopicName(state : State, topicId : Nat) : ?Text;

  // Add a subscriber to a topic. Returns false if the topic doesn't exist
  public func add(state : State, topicId : Nat, email : Text) : Bool;

  // Remove a subscriber from a topic. Their unsubscribe link stops working; a re-subscription gets a fresh one on the next send.
  public func remove(state : State, tokens : UnsubscribeTokens.State, topicId : Nat, email : Text);

  // Remove a subscriber from all topics
  public func removeFromAllTopics(state : State, tokens : UnsubscribeTokens.State, email : Text);

  // List all subscribers alongside their verification status for a given topic. Returns null if the topic doesn't exist.
  public func list(state : State, verifiedEmails : VerifiedEmails.State, topicId : Nat) : ?[(Text, Bool)];

  // List all verified subscribers for a given topic. Returns null if the topic doesn't exist.
  public func verified(state : State, verifiedEmails : VerifiedEmails.State, topicId : Nat) : ?[Text];

  // Return whether a subscriber is subscribed to a topic
  public func isSubscribed(state : State, topicId : Nat, email : Text) : Bool;

  // List all topics a subscriber is subscribed to.
  public func listTopicsForSubscriber(state : State, email : Text) : [Topic];

  // Returns the count of subscribers for a given topic
  public func count(state : State, topicId : Nat) : Nat;

  // Returns the count of verified subscribers for a given topic
  public func verifiedCount(state : State, verifiedEmails : VerifiedEmails.State, topicId : Nat) : Nat;
};
```

### Unsubscribe link tokens

Use the prefabricated module `mo:caffeineai-email-marketing/unsubscribeTokens.mo` which cannot be modified. It holds one token per subscriber and topic, minted on the first send and kept so the link in older mail keeps working, dropped when the recipient uses it. The app only declares the state and passes it around.

```mo:caffeineai-email-marketing/unsubscribeTokens.mo
module {
  public type State = {
    byToken : Map.Map<Text, { email : Text; topicId : Nat }>;
    bySubscription : Map.Map<Text, Text>;
  };

  public func new() : State;

  public func size(state : State) : Nat;
};
```

### To handle the unsubscribe link

Use the prefabricated module `mo:caffeineai-email-marketing/unsubscribeMixin.mo` which cannot be modified.

`MixinEmailUnsubscribe` takes the subscribers state and the token state. It adds `_caffeineEmailUnsubscribe(token)`, which the app's frontend calls from the unsubscribe page: it removes the subscriber from the topic the token was minted for and returns the topic's name. Anyone holding a valid token can call it, the anonymous principal included, so the recipient needs no account. It also keeps the legacy `_caffeineEmailUnsubscribeFromTopic` callback so links in mail sent before this version keep working.

```mo:caffeineai-email-marketing/unsubscribeMixin.mo
import MixinEmailUnsubscribe "mo:caffeineai-email-marketing/unsubscribeMixin";

mixin (subscribers : Subscribers.State, unsubscribeTokens : UnsubscribeTokens.State) {
  public shared func _caffeineEmailUnsubscribe(token : Text) : async { #ok : { topic : ?Text }; #err : Text };
};
```

### For sending direct marketing emails from the backend

- Use the `sendMarketingEmail` function of the prefabricated module `mo:caffeineai-email-marketing/marketing.mo` which cannot be modified. Do NOT call `EmailClient.broadcastViaGateway` from app code: this module prepares the tokens, the link template and the `List-Unsubscribe` header it sends.
- This MUST be used alongside the subscribers.mo module and unsubscribeMixin.mo module
- `sendMarketingEmail` sends to every verified subscriber of the topic. Its `personalise` argument is a function from an email address to that recipient's substitution name/value pairs (`[]` for none).
  - These substitutions allow the email to be personalised for each recipient.
  - If the email body contains the substitution name in double curly braces it is replaced by the substitution value in the email to that recipient.
- `sendMarketingEmailTo` sends to explicit addresses, cut down to the verified subscribers of the topic, with the same `personalise` argument. `#err` when none remain.
- It returns a Result which is #ok if the email is sent successfully otherwise #err(error) with the error text.
- The placeholder text {{UNSUBSCRIBE_URL}} in the htmlBody is replaced with the recipient's unsubscribe link on the app's `/unsubscribe` page; when the placeholder is missing an unsubscribe line is appended to the body. Every copy also carries a `List-Unsubscribe` header with the same link, so mail clients show their own unsubscribe control.
- The link lands on the app's `/unsubscribe` page, and the `List-Unsubscribe` header is added, when the canister has the mail gateway key (`INTEGRATIONS_GATEWAY_URL` / `INTEGRATIONS_GATEWAY_API_KEY`, injected by the platform where the gateway is enabled). Without the key the mail goes through the transport canister as before: the transport fills `{{UNSUBSCRIBE_URL}}` with its own link and the click is handled through `_caffeineEmailUnsubscribeFromTopic`. The app code is the same either way.

```mo:caffeineai-email-marketing/marketing.mo
module {
  // To every verified subscriber of the topic; `personalise` gives each
  // recipient's substitutions. #err when the topic is unknown or empty.
  public func sendMarketingEmail(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    tokens : UnsubscribeTokens.State,
    topicId : Nat,
    fromUsername : Text,
    subject : Text,
    htmlBody : Text,
    personalise : Text -> [(Text, Text)],
  ) : async { #ok; #err : Text };

  // To those of the given addresses that are verified subscribers of the
  // topic. #err when the topic is unknown or none of them is.
  public func sendMarketingEmailTo(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    tokens : UnsubscribeTokens.State,
    topicId : Nat,
    fromUsername : Text,
    emails : [Text],
    subject : Text,
    htmlBody : Text,
    personalise : Text -> [(Text, Text)],
  ) : async { #ok; #err : Text };

  // The addresses either function would send to: the topic's verified
  // subscribers, or those of them in `among`. Null for an unknown topic.
  public func recipients(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    topicId : Nat,
    among : ?[Text],
  ) : ?[Text];
};
```

### Example usage for an app which can send marketing emails to users who are subscribed to topics managed by the admin

```motoko filepath=src/backend/main.mo
import Array "mo:core/Array";
import Runtime "mo:core/Runtime";
import Option "mo:core/Option";
import Principal "mo:core/Principal";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Text "mo:core/Text";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import EmailMarketing "mo:caffeineai-email-marketing/marketing";
import MixinEmailUnsubscribe "mo:caffeineai-email-marketing/unsubscribeMixin";
import EmailSubscribers "mo:caffeineai-email-marketing/subscribers";
import UnsubscribeTokens "mo:caffeineai-email-marketing/unsubscribeTokens";
import EmailVerification "mo:caffeineai-email-verification/verification";
import MixinEmailVerification "mo:caffeineai-email-verification/verificationMixin";
import VerificationTokens "mo:caffeineai-email-verification/verificationTokens";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";

actor {
  public type UserProfile = {
    name : Text;
    email : Text;
  };

  // Include authorization component
  let accessControlState : AccessControl.AccessControlState;
  include MixinAuthorization(accessControlState, null);

  // Store a map of caller principal to UserProfile
  let userProfiles : Map.Map<Principal, UserProfile>;

  // Store a set of emails for uniqueness check
  let emails : Set.Set<Text>;

  // Stores which emails are verified
  let verifiedEmails : VerifiedEmails.State;

  // Pending verification links, until clicked or expired
  let verificationTokens : VerificationTokens.State;

  // In this example we use a single hardcoded topic.
  // In general there could be CRUD endpoints for the admin to manage email subscription topics.
  transient let newsletterTopic = "Newsletter";

  // Store the email subscribers per topic
  let emailSubscribers : EmailSubscribers.State;

  // Unsubscribe link tokens, one per subscriber and topic
  let unsubscribeTokens : UnsubscribeTokens.State;

  // Include this mixin to handle the unsubscribe link which updates the EmailSubscribers state
  include MixinEmailUnsubscribe(emailSubscribers, unsubscribeTokens);

  // Include this mixin to handle the verification link which updates the VerifiedEmails state
  include MixinEmailVerification(verifiedEmails, verificationTokens);

  func getUserInternal(caller : Principal) : UserProfile {
    userProfiles.get(caller) ?? Runtime.trap("User profile does not exist!");
  };

  public shared ({ caller }) func registerUser(name : Text, email : Text) : async () {
    // Check if the user already exists
    if (userProfiles.containsKey(caller)) {
      Runtime.trap("User already registered");
    };
    // Check if the email is already used
    if (emails.contains(email)) {
      Runtime.trap("Email already taken");
    };
    // Add a user record
    userProfiles.add(
      caller,
      {
        name;
        email;
      },
    );
    emails.add(email);
    // Subscribe the user to the Newsletter topic by default
    let topicId = EmailSubscribers.getTopicId(emailSubscribers, newsletterTopic)
      ?? Runtime.trap("Newsletter topic not found");
    ignore EmailSubscribers.add(emailSubscribers, topicId, email);
    // Send a verification email
    let result = await EmailVerification.sendVerificationEmail(
      verificationTokens,
      "no-reply",
      [email],
      "Welcome to Our Service",
      "Hello " # name # ",<br><br>Thank you for registering with our service.<br><br>Please <a href=\"{{VERIFICATION_URL}}\">click here</a> to verify your email address.<br><br>By clicking on the verification link you also agree to sign-up to the monthly Newsletter which you can unsubscribe from at any time.<br><br>Best regards,<br>The Team",
    );
    switch (result) {
      case (#ok) {};
      case (#err(error)) {
        Runtime.trap("Failed to send verification email: " # error);
      };
    };
  };

  public shared ({ caller }) func addTopic(name : Text) : async Nat {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can add topics");
    };
    EmailSubscribers.addTopic(emailSubscribers, name);
  };

  public shared ({ caller }) func removeTopic(topicId : Nat) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can remove topics");
    };
    EmailSubscribers.removeTopic(emailSubscribers, unsubscribeTokens, topicId);
  };

  public shared ({ caller }) func renameTopic(topicId : Nat, newName : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can rename topics");
    };
    let success = EmailSubscribers.renameTopic(emailSubscribers, topicId, newName);
    if (not success) {
      Runtime.trap("Failed to rename topic");
    };
  };

  public shared ({ caller }) func subscribeToTopic(topicId : Nat) : async () {
    let userProfile = getUserInternal(caller);
    ignore EmailSubscribers.add(emailSubscribers, topicId, userProfile.email);
  };

  public shared ({ caller }) func unsubscribeFromTopic(topicId : Nat) : async () {
    let userProfile = getUserInternal(caller);
    EmailSubscribers.remove(emailSubscribers, unsubscribeTokens, topicId, userProfile.email);
  };

  public shared ({ caller }) func sendMarketingEmail(topicId : Nat, subject : Text, htmlBody : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can send the newsletter");
    };
    // Ensure the email body contains the unsubscribe link placeholder
    let finalHtmlBody = if (htmlBody.contains(#text "{{UNSUBSCRIBE_URL}}")) {
      htmlBody;
    } else {
      htmlBody # "<br><br>To unsubscribe <a href=\"{{UNSUBSCRIBE_URL}}\">click here</a>";
    };
    // Sent to every verified subscriber of the topic; NAME personalises each copy
    let result = await EmailMarketing.sendMarketingEmail(
      emailSubscribers,
      verifiedEmails,
      unsubscribeTokens,
      topicId,
      "no-reply",
      subject,
      finalHtmlBody,
      func(email) {
        switch (userProfiles.values().find(func(user) { user.email == email })) {
          case (?user) { [("NAME", user.name)] };
          case (null) { [] };
        };
      },
    );
    switch (result) {
      case (#ok) {};
      case (#err(error)) {
        Runtime.trap("Failed to send newsletter: " # error);
      };
    };
  };

  public query ({ caller }) func listTopics() : async [EmailSubscribers.Topic] {
    EmailSubscribers.listTopics(emailSubscribers);
  };

  // Admin function to list topic subscribers and whether the email is verified or not
  public query ({ caller }) func listSubscribers(topicId : Nat) : async [(Text, Bool)] {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can list topic subscribers");
    };
    EmailSubscribers.list(emailSubscribers, verifiedEmails, topicId).get([]);
  };

  public query ({ caller }) func isCallerSubscribedToTopic(topicId : Nat) : async Bool {
    let userProfile = getUserInternal(caller);
    EmailSubscribers.listTopicsForSubscriber(emailSubscribers, userProfile.email).find(
      func(topic) { topic.id == topicId }
    ).isSome();
  };

  public query ({ caller }) func isCallerEmailVerified() : async Bool {
    let userProfile = getUserInternal(caller);
    VerifiedEmails.contains(verifiedEmails, userProfile.email);
  };
};
```

The migration chain head — `newsletterTopic` is `transient`, so the migration repeats the topic literal instead of referencing it:

```motoko filepath=src/backend/migrations/00000000_000000.mo
import Map "mo:core/Map";
import Set "mo:core/Set";
import AccessControl "mo:caffeineai-authorization/access-control";
import EmailSubscribers "mo:caffeineai-email-marketing/subscribers";
import UnsubscribeTokens "mo:caffeineai-email-marketing/unsubscribeTokens";
import VerificationTokens "mo:caffeineai-email-verification/verificationTokens";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";

module {
  type UserProfile = {
    name : Text;
    email : Text;
  };

  type NewActor = {
    accessControlState : AccessControl.AccessControlState;
    userProfiles : Map.Map<Principal, UserProfile>;
    emails : Set.Set<Text>;
    verifiedEmails : VerifiedEmails.State;
    verificationTokens : VerificationTokens.State;
    emailSubscribers : EmailSubscribers.State;
    unsubscribeTokens : UnsubscribeTokens.State;
  };

  public func migration(_old : {}) : NewActor {
    {
      accessControlState = AccessControl.initState();
      userProfiles = Map.empty<Principal, UserProfile>();
      emails = Set.empty<Text>();
      verifiedEmails = VerifiedEmails.new();
      verificationTokens = VerificationTokens.new();
      emailSubscribers = EmailSubscribers.new(["Newsletter"]);
      unsubscribeTokens = UnsubscribeTokens.new();
    };
  };
};
```

## Upgrading from the previous version

An app built with `caffeineai-email-marketing` 0.1.x needs all of these (and the upgrade steps of [extension-email-verification](../extension-email-verification/SKILL.md)):

1. Re-pin: `mops add caffeineai-email-marketing@0.2.0`, `mops add caffeineai-email-verification@0.2.0` and `mops add caffeineai-email@0.3.0`.
2. Declare the new stable field `unsubscribeTokens : UnsubscribeTokens.State` and add it to the migration chain (a new migration file initialising it with `UnsubscribeTokens.new()`; `emailSubscribers` keeps its shape and its data, and existing subscribers get their tokens on the next send).
3. Change `include MixinEmailUnsubscribe(emailSubscribers)` to `include MixinEmailUnsubscribe(emailSubscribers, unsubscribeTokens)`.
4. Pass `unsubscribeTokens` to `EmailSubscribers.remove`, `EmailSubscribers.removeFromAllTopics` and `EmailSubscribers.removeTopic`: removing a subscriber also retires the unsubscribe link in mail already sent to them.
5. Replace `EmailClient.sendMarketingEmail(topicId, fromUsername, recipients, subject, htmlBody)` with `EmailMarketing.sendMarketingEmail(emailSubscribers, verifiedEmails, unsubscribeTokens, topicId, fromUsername, subject, htmlBody, personalise)` (import `mo:caffeineai-email-marketing/marketing`), which sends to the topic's verified subscribers itself; the recipient-list code goes, and the per-recipient substitutions move into `personalise`. An app that has to address a subset uses `sendMarketingEmailTo`, which sends to those of its addresses that are verified subscribers of the topic.
6. Add the frontend package and the `/unsubscribe` route described below.

# Frontend

Install `@caffeineai/email-marketing`. It exports the prefabricated hook `useUnsubscribe`, which cannot be modified:

```typescript filepath=@caffeineai/email-marketing/hooks/useUnsubscribe.ts
export interface UnsubscribeActor {
  // the bindgen wrapper turns Candid's optional text into an optional field
  _caffeineEmailUnsubscribe(token: string): Promise<{ ok: { topic?: string | null } } | { err: string }>;
}

// ready: a token is in the URL and nothing was sent yet
// pending: the backend call is in flight
// done: the address is unsubscribed; `topic` names the topic when it still exists
// invalid: the URL has no token, or the backend rejected it
// error: the backend call failed; `error` holds the message
export type UnsubscribeStatus = 'ready' | 'pending' | 'done' | 'invalid' | 'error';

export declare function useUnsubscribe(actor: UnsubscribeActor | null | undefined): {
  status: UnsubscribeStatus;
  topic: string | null;
  error: string | null;
  hasToken: boolean;
  // True once the actor is available, a token is present and nothing was sent yet
  isReady: boolean;
  // Unsubscribes through the backend. Call it from a button click only.
  confirm: () => Promise<void>;
};
```

Rules for the unsubscribe page:

- Add a route at `/unsubscribe` that is reachable WITHOUT signing in: recipients open it from their mail client and have no session. The backend method takes the token as its only credential, so the anonymous actor from `useActor` is enough.
- Read the token with the hook (it takes `?token=` from the URL itself) and render a button that calls `confirm()`. NEVER call `confirm()` on page load or in an effect: mail clients, link previewers and scanners fetch the URL without a person behind it, and a fetch must unsubscribe nobody.
- Show the outcome from `status`: `done` naming the `topic` when present, `invalid` for a missing or already used link, `error` with the message.

Example page:

```typescript filepath=src/frontend/src/pages/UnsubscribePage.tsx
import { useUnsubscribe } from '@caffeineai/email-marketing';
import { useActor } from '@caffeineai/core-infrastructure';
import { createActor } from '@/backend';

export function UnsubscribePage() {
  const { actor } = useActor(createActor);
  const { status, topic, error, isReady, confirm } = useUnsubscribe(actor);

  if (status === 'done') return <p>You are unsubscribed{topic ? ` from ${topic}` : ''}.</p>;
  if (status === 'invalid') return <p>{error ?? 'This unsubscribe link is invalid or was already used.'}</p>;
  if (status === 'error') return <p>Something went wrong: {error}</p>;

  return (
    <button onClick={() => void confirm()} disabled={!isReady}>
      {status === 'pending' ? 'Unsubscribing…' : 'Unsubscribe'}
    </button>
  );
}
```

Register it with the app's TanStack Router alongside the other routes, as a child of the root route with `path: '/unsubscribe'`, outside any authenticated layout.

If there is a UI for the admin to enter the content of a marketing email then indicate that the placeholder text {{UNSUBSCRIBE_URL}} should be present in the email body.
