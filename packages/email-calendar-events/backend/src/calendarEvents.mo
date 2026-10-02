import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Prim "mo:⛔";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Text "mo:core/Text";
import EmailClient "mo:caffeineai-email/emailClient";
import EmailService "mo:caffeineai-email/emailService";
import MailV2Api "mo:caffeine-integrations-mail-client/Apis/MailV2Api";
import { type MailV2BroadcastResponse } "mo:caffeine-integrations-mail-client/Models/MailV2BroadcastResponse";
import MailV2CalendarEventMethod "mo:caffeine-integrations-mail-client/Values/MailV2CalendarEventMethod";
import MailV2CalendarEventRole "mo:caffeine-integrations-mail-client/Values/MailV2CalendarEventRole";

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

  public func new() : State {
    let state = {
      var events = List.empty<CalendarEvent>();
      var uidMap = Map.empty<Text, Nat>();
    };
    state;
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
    attendees : [Attendee],
  ) : ?CalendarEvent {
    if (self.uidMap.containsKey(uid)) {
      return null;
    };
    let event : CalendarEvent = {
      uid;
      sequence = 0;
      method = #request;
      summary;
      description;
      location;
      startTime;
      endTime;
      organizer;
      attendees;
    };
    let index = self.events.size();
    self.events.add(event);
    self.uidMap.add(
      uid,
      index,
    );
    ?event;
  };

  public func update(
    self : State,
    uid : Text,
    summary : ?Text,
    description : ?Text,
    location : ?Text,
    startTime : ?Nat64,
    endTime : ?Nat64,
    organizer : ?Organizer,
    attendees : ?[Attendee],
  ) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        let event = self.events.at(index);
        let updated = {
          event with
          sequence = event.sequence + 1;
          summary = switch (summary) {
            case (?s) { s };
            case (_) { event.summary };
          };
          description = switch (description) {
            case (?d) { d };
            case (_) { event.description };
          };
          location = switch (location) {
            case (?l) { l };
            case (_) { event.location };
          };
          startTime = switch (startTime) {
            case (?st) { st };
            case (_) { event.startTime };
          };
          endTime = switch (endTime) {
            case (?et) { et };
            case (_) { event.endTime };
          };
          organizer = switch (organizer) {
            case (?o) { o };
            case (_) { event.organizer };
          };
          attendees = switch (attendees) {
            case (?a) { a };
            case (_) { event.attendees };
          };
        };
        self.events.put(index, updated);
        ?updated;
      };
      case (_) { null };
    };
  };

  public func addAttendees(
    self : State,
    uid : Text,
    attendees : [Attendee],
  ) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        let event = self.events.at(index);
        let newAttendees = event.attendees.concat(attendees);
        let updated = {
          event with
          sequence = event.sequence + 1;
          attendees = newAttendees;
        };
        self.events.put(index, updated);
        ?updated;
      };
      case (_) { null };
    };
  };

  public func removeAttendees(
    self : State,
    uid : Text,
    attendees : [Text],
  ) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        let event = self.events.at(index);
        let filteredAttendees = event.attendees.filter(
          func(attendee) {
            not attendees.any(func(email) { email == attendee.who.email });
          }
        );
        let updated = {
          event with
          sequence = event.sequence + 1;
          attendees = filteredAttendees;
        };
        self.events.put(index, updated);
        ?updated;
      };
      case (_) { null };
    };
  };

  public func cancel(self : State, uid : Text) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        let event = self.events.at(index);
        let updated = {
          event with
          method = #cancel;
          sequence = event.sequence + 1;
        };
        self.events.put(index, updated);
        ?updated;
      };
      case (_) { null };
    };
  };

  public func delete(self : State, uid : Text) {
    self.uidMap.remove(uid);
    self.events := self.events.filter(
      func(event) {
        event.uid != uid;
      }
    );
  };

  public func get(self : State, uid : Text) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        ?self.events.at(index);
      };
      case (_) { null };
    };
  };

  // Iterate over all calendar events older to newer
  public func iter(self : State) : Iter.Iter<CalendarEvent> {
    self.events.values();
  };

  // Iterate over all calendar events newer to older
  public func reverse(self : State) : Iter.Iter<CalendarEvent> {
    self.events.reverseValues();
  };

  // One invitation copy per attendee: through the mail gateway's
  // calendar-event route when the canister has the gateway key, through the
  // transport canister otherwise.
  public func sendCalendarEvent(fromUsername : Text, event : CalendarEvent) : async EmailClient.SendResult {
    if (EmailClient.gatewayConfigured<system>()) {
      await* gatewayCalendarEvent(fromUsername, event);
    } else {
      await transportCalendarEvent(fromUsername, event);
    };
  };

  // The transport canister takes the organizer as a full mailbox, so this path
  // builds it from the sender and the app's own host, read from the
  // platform-injected FRONTEND_URL.
  func transportCalendarEvent<system>(fromUsername : Text, event : CalendarEvent) : async EmailClient.SendResult {
    let maxEmailCost = 50_000_000_000; // 50B CYCLES

    if (Cycles.balance() < maxEmailCost) {
      return #err("Not enough cycles to send calendar event email");
    };

    let ?url = Prim.envVar<system>("FRONTEND_URL") else {
      return #err("FRONTEND_URL is not set: the organizer address needs the app's domain");
    };
    let organizer = { email = fromUsername # "@" # hostOf(url); name = event.organizer.name };

    let integrationsCanisterId = await EmailClient.getIntegrationsCanisterId();
    let emailService = actor (integrationsCanisterId.toText()) : EmailService.EmailService;

    try {
      let method = switch (event.method) {
        case (#request) { #Request };
        case (#publish) { #Publish };
        case (#cancel) { #Cancel };
      };

      let attendees = event.attendees.map(
        func(attendee) {
          {
            who = attendee.who;
            role = switch (attendee.role) {
              case (#chair) { #Chair };
              case (#required) { #Required };
              case (#optional) { #Optional };
              case (#notParticipating) { #NotParticipating };
            };
          };
        }
      );

      let response = await (with cycles = maxEmailCost) emailService.send_calendar_event({
        from_username = fromUsername;
        uid = event.uid;
        sequence = event.sequence;
        method;
        summary = event.summary;
        description = event.description;
        location = event.location;
        start_time = event.startTime;
        end_time = event.endTime;
        organizer;
        attendees;
      });

      switch (response.result) {
        case (#Ok(_)) { #ok };
        case (#Err(error)) { return #err(debug_show (error)) };
      };
    } catch (error) {
      return #err("Failed to send calendar event email: " # error.message());
    };
  };

  public func hostOf(url : Text) : Text {
    let authority = url.stripStart(#text "https://") ?? (url.stripStart(#text "http://") ?? url);
    Text.fromIter(authority.chars().takeWhile(func(c : Char) : Bool { c != '/' and c != ':' }));
  };

  func gatewayCalendarEvent<system>(fromUsername : Text, event : CalendarEvent) : async* EmailClient.SendResult {
    let method = MailV2CalendarEventMethod.toText(event.method);
    let attendees = event.attendees.map(
      func(attendee) {
        {
          email = attendee.who.email;
          name = attendee.who.name;
          role = MailV2CalendarEventRole.toText(attendee.role);
        };
      }
    );
    var response : ?MailV2BroadcastResponse = null;
    try {
      await* EmailClient.sendOnce(
        func(idempotencyKey : Text) : async* () {
          response := ?(await* MailV2Api.mailV2CalendarEvent(
            EmailClient.gatewayConfig<system>(),
            idempotencyKey,
            {
              fromUsername;
              event = {
                uid = event.uid;
                sequence = Nat32.toNat(event.sequence);
                method;
                summary = event.summary;
                description = event.description;
                location = event.location;
                startTime = Nat64.toNat(event.startTime);
                endTime = Nat64.toNat(event.endTime);
                organizer = event.organizer;
                attendees;
              };
            },
          ));
        }
      );
      EmailClient.broadcastResult(response ?? Runtime.unreachable());
    } catch (error) {
      #err("Failed to send calendar event email: " # error.message());
    };
  };
};
