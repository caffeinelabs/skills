---
name: extension-email-verification
description: Support for sending an email with a link the recipient can click to prove they own the email address.
version: 0.2.0
compatibility:
  mops:
    caffeineai-email-verification: "~0.2.0"
    caffeineai-email: "~0.3.0"
  npm:
    "@caffeineai/email-verification": "~0.2.0"
caffeineai-subscription: [plus, pro]
---

# Email — Verification
Email verification extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds email address verification via a click-to-verify link that lands on the app's own frontend. The backend mints and stores the link token (`verificationTokens`) and confirms it through `MixinEmailVerification`; `verifiedEmails` tracks verified addresses. The frontend renders the `/verify-email` page, where the recipient clicks a button to confirm.

## Required Setup Checklist

All five steps are mandatory.

1. **mops dependencies** — `mops add caffeineai-email-verification` and `mops add caffeineai-email`.
2. **Two stable state fields** — `verifiedEmails : VerifiedEmails.State` and `verificationTokens : VerificationTokens.State`, initialised in the migration chain head with `VerifiedEmails.new()` and `VerificationTokens.new()`.
3. **Mixin invocation** — `include MixinEmailVerification(verifiedEmails, verificationTokens)` in `main.mo`.
4. **Sending** — `EmailVerification.sendVerificationEmail(verificationTokens, fromUsername, recipients, subject, htmlBody)`; the body MUST contain `{{VERIFICATION_URL}}`.
5. **Frontend npm package and route** — `@caffeineai/email-verification` installed, and a public route `/verify-email` (reachable without signing in) that renders a button calling `confirm()`.

CRITICAL: the link in the email is `https://<app domain>/verify-email?token=…`. Without the frontend route the recipient lands on a missing page and the address is never verified.

# Backend

## This component is for sending an email to users with a verification link which the user can click to prove they own the email address.

### To check if an email address has been verified

Use the prefabricated module `mo:caffeineai-email-verification/verifiedEmails.mo` which cannot be modified.

```mo:caffeineai-email-verification/verifiedEmails.mo
module {
  public type State = {
    verifiedEmails : Set.Set<Text>;
  };

  public func new() : State;

  public func contains(state : State, email : Text) : Bool;

  public func iter(state : State) : Iter.Iter<Text>;

  public func size(state : State) : Nat;
};
```

To check whether an email is verified use the `contains` function. Do NOT try to track the email verification status independently by storing it against the user profile.

### Pending verification links

Use the prefabricated module `mo:caffeineai-email-verification/verificationTokens.mo` which cannot be modified. It holds the tokens of links sent but not yet clicked; a token is single use and expires after 24 hours. The app only declares the state and passes it around.

```mo:caffeineai-email-verification/verificationTokens.mo
module {
  public type State = {
    tokens : Map.Map<Text, { email : Text; createdAt : Time.Time }>;
  };

  public func new() : State;

  public func size(state : State) : Nat;
};
```

### To handle the verification link

Use the prefabricated module `mo:caffeineai-email-verification/verificationMixin.mo` which cannot be modified.

`MixinEmailVerification` takes both states. It adds `_caffeineEmailConfirmVerification(token)`, which the app's frontend calls from the verification page: it marks the address the token was sent to as verified and returns it. Anyone holding a valid token can call it, the anonymous principal included, so the recipient needs no account. It also keeps the legacy `_caffeineEmailVerify` callback so links in mail sent before this version keep working.

```mo:caffeineai-email-verification/verificationMixin.mo
import MixinEmailVerification "mo:caffeineai-email-verification/verificationMixin";

mixin (verifiedEmails : VerifiedEmails.State, verificationTokens : VerificationTokens.State) {
  public shared func _caffeineEmailConfirmVerification(token : Text) : async { #ok : Text; #err : Text };
};
```

### For sending users a verification email

- Use the `sendVerificationEmail` function of the prefabricated module `mo:caffeineai-email-verification/verification.mo` which cannot be modified. Do NOT call `EmailClient.broadcastViaGateway` from app code: this module prepares the tokens and the link template it sends.
- It returns a SendResult which is #ok if the email is sent successfully otherwise #err(error) with the error text.
- Each recipient receives an individual email with a specific verification link for them, pointing at the app's `/verify-email` page.
- The htmlBody MUST contain the placeholder text {{VERIFICATION_URL}}; the function returns #err when it is missing.
- The link lands on the app's `/verify-email` page when the canister has the mail gateway key (`INTEGRATIONS_GATEWAY_URL` / `INTEGRATIONS_GATEWAY_API_KEY`, injected by the platform where the gateway is enabled). Without the key the mail goes through the transport canister as before: the transport fills `{{VERIFICATION_URL}}` with its own link and the click is confirmed through `_caffeineEmailVerify`. The app code is the same either way.

```mo:caffeineai-email-verification/verification.mo
module {
  public func sendVerificationEmail(
    tokens : VerificationTokens.State,
    fromUsername : Text,
    recipients : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async { #ok; #err : Text };
};
```

### Example usage with endpoints for registering a user and for checking whether a user is verified.

```motoko filepath=src/backend/main.mo
import Map "mo:core/Map";
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import EmailVerification "mo:caffeineai-email-verification/verification";
import MixinEmailVerification "mo:caffeineai-email-verification/verificationMixin";
import VerificationTokens "mo:caffeineai-email-verification/verificationTokens";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";

actor {
  // Stores which emails are verified
  let verifiedEmails : VerifiedEmails.State;

  // Pending verification links, until clicked or expired
  let verificationTokens : VerificationTokens.State;

  // User profiles storage
  let users : Map.Map<Principal, User>;

  // Email to principal mapping for uniqueness check
  let emailToPrincipal : Map.Map<Text, Principal>;

  // Handles the verification link and updates the verifiedEmails store
  include MixinEmailVerification(verifiedEmails, verificationTokens);

  type User = {
    name : Text;
    email : Text;
  };

  public shared ({ caller }) func registerUser(email : Text, name : Text) : async () {
    if (users.containsKey(caller)) {
      Runtime.trap("User already registered");
    };
    if (emailToPrincipal.containsKey(email)) {
      Runtime.trap("Email already registered");
    };

    let user : User = {
      name;
      email;
    };
    users.add(caller, user);
    emailToPrincipal.add(email, caller);
    let result = await EmailVerification.sendVerificationEmail(
      verificationTokens,
      "no-reply",
      [email],
      "Welcome to Our Service",
      "Hello " # name # ",<br><br>Thank you for registering with our service. Please <a href=\"{{VERIFICATION_URL}}\">click here</a> to verify your email address<br><br>Best regards,<br>The Team",
    );

    switch (result) {
      case (#ok) {};
      case (#err(error)) {
        Runtime.trap("Couldn't send verification email: " # error);
      };
    };
  };

  public shared ({ caller }) func isEmailVerified() : async Bool {
    let user = users.get(caller) ?? Runtime.trap("User not registered");
    VerifiedEmails.contains(verifiedEmails, user.email);
  };
};
```

The migration chain head:

```motoko filepath=src/backend/migrations/00000000_000000.mo
import Map "mo:core/Map";
import VerificationTokens "mo:caffeineai-email-verification/verificationTokens";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";

module {
  type User = {
    name : Text;
    email : Text;
  };

  type NewActor = {
    verifiedEmails : VerifiedEmails.State;
    verificationTokens : VerificationTokens.State;
    users : Map.Map<Principal, User>;
    emailToPrincipal : Map.Map<Text, Principal>;
  };

  public func migration(_old : {}) : NewActor {
    {
      verifiedEmails = VerifiedEmails.new();
      verificationTokens = VerificationTokens.new();
      users = Map.empty<Principal, User>();
      emailToPrincipal = Map.empty<Text, Principal>();
    };
  };
};
```

## Upgrading from the previous version

An app built with `caffeineai-email-verification` 0.1.x and `caffeineai-email` 0.2.x needs all of these:

1. Re-pin: `mops add caffeineai-email-verification@0.2.0` and `mops add caffeineai-email@0.3.0`.
2. Declare the new stable field `verificationTokens : VerificationTokens.State` and add it to the migration chain (a new migration file initialising it with `VerificationTokens.new()`; `verifiedEmails` keeps its shape and its data).
3. Change `include MixinEmailVerification(verifiedEmails)` to `include MixinEmailVerification(verifiedEmails, verificationTokens)`.
4. Replace `EmailClient.sendVerificationEmail(fromUsername, recipients, subject, htmlBody)` with `EmailVerification.sendVerificationEmail(verificationTokens, fromUsername, recipients, subject, htmlBody)` (import `mo:caffeineai-email-verification/verification`).
5. Add the frontend package and the `/verify-email` route described below.

# Frontend

Install `@caffeineai/email-verification`. It exports the prefabricated hook `useEmailVerification`, which cannot be modified:

```typescript filepath=@caffeineai/email-verification/hooks/useEmailVerification.ts
export interface EmailVerificationActor {
  _caffeineEmailConfirmVerification(token: string): Promise<{ ok: string } | { err: string }>;
}

// ready: a token is in the URL and nothing was sent yet
// pending: the backend call is in flight
// done: the address is verified; `email` holds it
// invalid: the URL has no token, or the backend rejected it
// error: the backend call failed; `error` holds the message
export type EmailVerificationStatus = 'ready' | 'pending' | 'done' | 'invalid' | 'error';

export declare function useEmailVerification(actor: EmailVerificationActor | null | undefined): {
  status: EmailVerificationStatus;
  email: string | null;
  error: string | null;
  hasToken: boolean;
  // True once the actor is available, a token is present and nothing was sent yet
  isReady: boolean;
  // Confirms the address through the backend. Call it from a button click only.
  confirm: () => Promise<void>;
};
```

Rules for the verification page:

- Add a route at `/verify-email` that is reachable WITHOUT signing in: recipients open it from their mail client and have no session. The backend method takes the token as its only credential, so the anonymous actor from `useActor` is enough.
- Read the token with the hook (it takes `?token=` from the URL itself) and render a button that calls `confirm()`. NEVER call `confirm()` on page load or in an effect: mail clients, link previewers and scanners fetch the URL without a person behind it, and a fetch must verify nothing.
- Show the outcome from `status`: `done` with the verified `email`, `invalid` for a missing, used or expired link (offer to request a new email), `error` with the message.

Example page:

```typescript filepath=src/frontend/src/pages/VerifyEmailPage.tsx
import { useEmailVerification } from '@caffeineai/email-verification';
import { useActor } from '@caffeineai/core-infrastructure';
import { createActor } from '@/backend';

export function VerifyEmailPage() {
  const { actor } = useActor(createActor);
  const { status, email, error, isReady, confirm } = useEmailVerification(actor);

  if (status === 'done') return <p>{email} is verified. You can close this page.</p>;
  if (status === 'invalid') return <p>{error ?? 'This verification link is invalid or has expired.'}</p>;
  if (status === 'error') return <p>Something went wrong: {error}</p>;

  return (
    <button onClick={() => void confirm()} disabled={!isReady}>
      {status === 'pending' ? 'Verifying…' : 'Verify my email address'}
    </button>
  );
}
```

Register it with the app's TanStack Router alongside the other routes, as a child of the root route with `path: '/verify-email'`, outside any authenticated layout.

If there is a UI for the admin to enter the content of a verification email then indicate that the placeholder text {{VERIFICATION_URL}} must be present in the email body.
