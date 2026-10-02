---
name: extension-email-calendar-events
description: Support for organising events/meetings and sending invitations by email.
version: 0.3.0
compatibility:
  mops:
    caffeineai-email-calendar-events: "~0.3.0"
    caffeineai-email: "~0.3.1"
    caffeineai-authorization: "~1.0.1"
caffeineai-subscription: [plus, pro]
---

# Email — Calendar Events
Calendar events email extension for [Caffeine AI](https://caffeine.ai?utm_source=caffeine-skill&utm_medium=referral).

## Overview

This skill adds support for organising events/meetings and sending iCalendar invitations by email. It provides CRUD operations for calendar events and email-based invitation delivery.

# Backend

## This component is for organising events/meetings and sending invitations by email

- Internally it builds and attaches an iCalendar file to each attendees's email
- This component does not yet support receiving RSVPs from attendees

### To add/update/cancel/delete/get/list calendar events

- Use the prefabricated module `mo:caffeineai-email-calendar-events/calendarEvents.mo` which cannot be modified.

```mo:caffeineai-email-calendar-events/calendarEvents.mo
module {
  public type CalendarEvent = {
    uid : Text;
    sequence : Nat32;
    method : CalendarEventMethod;
    summary : Text;
    description : Text;
    location : Text;
    startTime : Nat64;
    endTime : Nat64;
    organizer : Organizer;
    attendees : [Attendee];
  };

  public type CalendarEventMethod = {
    #request;
    #publish;
    #cancel;
  };

  // The organizer is the sender: the invitation comes from
  // `<fromUsername>@<app domain>` and that mailbox, under this display name,
  // is the ICS ORGANIZER and the first guest. Only attendees carry addresses.
  public type Organizer = {
    name : ?Text;
  };

  public type Mailbox = {
    email : Text;
    name : ?Text;
  };

  public type Attendee = {
    who : Mailbox;
    role : CalendarEventRole;
  };

  public type CalendarEventRole = {
    #chair;
    #required;
    #optional;
    #notParticipating;
  };

  public type State = {
    var events : List.List<CalendarEvent>;
    var uidMap : Map.Map<Text, Nat>;
  };

  public func add(
    self : State,
    uid : Text,
    summary : Text,
    description : Text,
    location : Text,
    startTime : Nat64,
    endTime : Nat64,
    organizer : Organizer,
    attendees : [Attendee]
  ) : ?CalendarEvent;

  // update, addAttendees, removeAttendees and cancel store the change with
  // the next sequence number and return the stored record. Send that record:
  // calendars apply an update or a cancellation only when its sequence is
  // higher than the one they hold.
  public func update(
    self : State,
    uid : Text,
    summary : ?Text,
    description : ?Text,
    location : ?Text,
    startTime : ?Nat64,
    endTime : ?Nat64,
    organizer : ?Organizer,
    attendees : ?[Attendee]
  ) : ?CalendarEvent;

  public func addAttendees(
    self : State,
    uid : Text,
    attendees : [Attendee]
  ) : ?CalendarEvent;

  public func removeAttendees(
    self : State,
    uid : Text,
    attendees : [Text]
  ) : ?CalendarEvent;

  public func cancel(self : State, uid : Text) : ?CalendarEvent;

  public func delete(self : State, uid : Text);

  public func get(self : State, uid : Text) : ?CalendarEvent;

  // Iterate over all calendar events older to newer
  public func iter(self : State) : Iter.Iter<CalendarEvent>;

  // Iterate over all calendar events newer to older
  public func reverse(self : State) : Iter.Iter<CalendarEvent>;

  // One invitation copy per attendee from `<fromUsername>@<app domain>`, the
  // organizer's mailbox, through the mail gateway or the transport canister.
  public func sendCalendarEvent(fromUsername : Text, event : CalendarEvent) : async { #ok; #err : Text };
}
```

### For sending calendar event invitations to attendees by email

- Use the `sendCalendarEvent` function of the same module. It sends one copy per attendee through the mail gateway when the canister has the gateway key (`INTEGRATIONS_GATEWAY_URL` / `INTEGRATIONS_GATEWAY_API_KEY`, injected by the platform where the gateway is enabled) and through the transport canister otherwise; the app code is the same either way. `caffeineai-email` is a dependency of this package, and the app does not call it for calendar mail.
- `fromUsername` is the local part of the sender only, such as `events` or `no-reply`. The invitation comes from `<fromUsername>@<app domain>`, and the app domain is the project's own, resolved by the mail gateway. Never pass a full address and never read or guess the domain in the app.
- The organizer is that same mailbox. `CalendarEvent.organizer` carries only a display name, `{ name = ?"Community Team" }`, shown as the ICS `ORGANIZER` and the first guest, so calendars see the invitation arrive from its organizer. Attendees are the only mailboxes with addresses; the organizer receives a copy only when also listed as an attendee. Do not model the organizer as a user with an email address.
- It returns `#ok` once the invitation was accepted for every attendee, otherwise `#err(error)` with the error text.

### Example usage for an app which can add/update/cancel/delete/get/list calendar events and send invitations to them by email

```motoko filepath=src/backend/main.mo
import Runtime "mo:core/Runtime";
import Principal "mo:core/Principal";
import Map "mo:core/Map";
import Random "mo:core/Random";
import Set "mo:core/Set";
import Iter "mo:core/Iter";
import Option "mo:core/Option";
import Text "mo:core/Text";
import AccessControl "mo:caffeineai-authorization/access-control";
import MixinAuthorization "mo:caffeineai-authorization/MixinAuthorization";
import CalendarEvents "mo:caffeineai-email-calendar-events/calendarEvents";
import Uuid "mo:caffeineai-email-calendar-events/uuid";

actor {
  public type UserProfile = {
    name : Text;
    email : Text;
  };

  // Include authorization component
  let accessControlState : AccessControl.AccessControlState;
  include MixinAuthorization(accessControlState, null);

  // Store a map of caller principal to UserProfile
  var userProfiles : Map.Map<Principal, UserProfile>;

  // Store a set of emails for uniqueness check
  var emails : Set.Set<Text>;

  // Store the calendar events
  let calendarEvents : CalendarEvents.State;

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
      }
    );
    emails.add(email);
  };

  public shared ({ caller }) func addCalendarEvent(summary : Text, description : Text, location : Text, startTimeMs : Nat64, endTimeMs : Nat64) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can add calendar events");
    };

    let organiser = userProfiles.get(caller)
      ?? Runtime.trap("Admin profile not found");

    let seed = await Random.blob();
    let uid = Uuid.generateV4(seed);

    if (
      calendarEvents.add(
        uid,
        summary,
        description,
        location,
        startTimeMs,
        endTimeMs,
        { name = ?organiser.name },
        userProfiles.values().map(
          func({ name; email }) {
            {
              who = { name = ?name; email };
              role = #required;
            };
          }
        ).toArray()
      ).isNull()
    ) {
      Runtime.trap("Failed to add calendar event");
    };
  };

  public shared ({ caller }) func updateEventDetails(uid : Text, summary : ?Text, description : ?Text, location : ?Text, startTimeMs : ?Nat64, endTimeMs : ?Nat64) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can update calendar events");
    };

    if (
      calendarEvents.update(
        uid,
        summary,
        description,
        location,
        startTimeMs,
        endTimeMs,
        null,
        null
      ).isNull()
    ) {
      Runtime.trap("Failed to update calendar event");
    };
  };

  public shared ({ caller }) func addEventAttendees(uid : Text, attendees : [CalendarEvents.Attendee]) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can add calendar event attendees");
    };

    if (calendarEvents.addAttendees(uid, attendees).isNull()) {
      Runtime.trap("Failed to add attendees to calendar event");
    };
  };

  public shared ({ caller }) func removeEventAttendees(uid : Text, attendees : [Text]) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can remove calendar event attendees");
    };

    if (calendarEvents.removeAttendees(uid, attendees).isNull()) {
      Runtime.trap("Failed to remove attendees from calendar event");
    };
  };

  public shared ({ caller }) func cancelEvent(uid : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can cancel calendar events");
    };

    // The returned record carries method #cancel and the bumped sequence,
    // which is what tells the attendees' calendars to drop the event.
    let cancelled = calendarEvents.cancel(uid)
      ?? Runtime.trap("Failed to cancel calendar event");

    switch (await CalendarEvents.sendCalendarEvent("events", cancelled)) {
      case (#ok) {};
      case (#err(error)) {
        Runtime.trap("Failed to send the cancellation: " # error);
      };
    };
  };

  public shared ({ caller }) func listEvents() : async [CalendarEvents.CalendarEvent] {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can list calendar events");
    };

    calendarEvents.iter().toArray();
  };

  public shared ({ caller }) func deleteEvent(uid : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can delete calendar events");
    };

    calendarEvents.delete(uid);
  };

  public shared ({ caller }) func sendEventInvitation(uid : Text) : async () {
    if (not (AccessControl.hasPermission(accessControlState, caller, #admin))) {
      Runtime.trap("Unauthorized: Only admins can send calendar event invitations");
    };

    let event = calendarEvents.get(uid)
      ?? Runtime.trap("Calendar event not found");

    ignore await CalendarEvents.sendCalendarEvent(
      "events",
      event
    );
  };
};
```

The migration chain head:

```motoko filepath=src/backend/migrations/00000000_000000.mo
import Map "mo:core/Map";
import Set "mo:core/Set";
import AccessControl "mo:caffeineai-authorization/access-control";
import CalendarEvents "mo:caffeineai-email-calendar-events/calendarEvents";

module {
  type UserProfile = {
    name : Text;
    email : Text;
  };

  type NewActor = {
    accessControlState : AccessControl.AccessControlState;
    var userProfiles : Map.Map<Principal, UserProfile>;
    var emails : Set.Set<Text>;
    calendarEvents : CalendarEvents.State;
  };

  public func migration(_old : {}) : NewActor {
    {
      accessControlState = AccessControl.initState();
      var userProfiles = Map.empty<Principal, UserProfile>();
      var emails = Set.empty<Text>();
      calendarEvents = CalendarEvents.new();
    };
  };
};
```

## Upgrading from the previous version

An app built with `caffeineai-email-calendar-events` 0.2.x re-pins with `mops add caffeineai-email-calendar-events@0.3.0` and `mops add caffeineai-email@0.3.1`. `CalendarEvent.organizer` is now an `Organizer` (`{ name : ?Text }`) instead of a `Mailbox`: the organizer address is the sender's, `<fromUsername>@<app domain>`, built by the mail gateway, so the app no longer supplies one. `add` and `update` take the new type, and an app that stored events adds a migration step that maps each stored `organizer` to `{ name = old.organizer.name }`.

An app built with `caffeineai-email-calendar-events` 0.1.x re-pins with `mops add caffeineai-email-calendar-events@0.2.0` and `mops add caffeineai-email@0.3.0`. `sendCalendarEvent` keeps its signature but moves from `EmailClient` to this module (`CalendarEvents.sendCalendarEvent`), and the event types (`CalendarEvent`, `Attendee`, `Mailbox`, `CalendarEventMethod`, `CalendarEventRole`) are this module's; an app that imported them from `EmailClient` switches the import and drops `EmailClient` when nothing else uses it. Invitations are now composed and sent by the mail gateway. `update`, `addAttendees`, `removeAttendees` and `cancel` now return the stored record (with the bumped sequence) instead of the previous one, so an app that sends the returned record after a change sends the right sequence.
