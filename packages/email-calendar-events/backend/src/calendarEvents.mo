import Array "mo:core/Array";
import Iter "mo:core/Iter";
import List "mo:core/List";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

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
    organizer : Mailbox;
    attendees : [Attendee];
  };

  public type CalendarEventMethod = {
    #request;
    #publish;
    #cancel;
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
    organizer : Mailbox,
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
    organizer : ?Mailbox,
    attendees : ?[Attendee],
  ) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        let event = self.events.at(index);
        self.events.put(
          index,
          {
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
          },
        );
        ?event;
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
        self.events.put(
          index,
          {
            event with
            sequence = event.sequence + 1;
            attendees = newAttendees;
          },
        );
        ?event;
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
        self.events.put(
          index,
          {
            event with
            sequence = event.sequence + 1;
            attendees = filteredAttendees;
          },
        );
        ?event;
      };
      case (_) { null };
    };
  };

  public func cancel(self : State, uid : Text) : ?CalendarEvent {
    switch (self.uidMap.get(uid)) {
      case (?index) {
        let event = self.events.at(index);
        self.events.put(
          index,
          {
            event with
            method = #cancel;
            sequence = event.sequence + 1;
          },
        );
        ?event;
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
};
