import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Prim "mo:⛔";
import Principal "mo:core/Principal";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import EmailService "emailService";

module {
  public type BroadcastEmailRecipient = EmailService.BroadcastEmailRecipient;

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
  ) : async SendResult {
    let maxEmailCost = 50_000_000_000; // 50B CYCLES

    let currentBalance = Cycles.balance();

    if (currentBalance < maxEmailCost) {
      return #err("Not enough cycles to send email");
    };

    let integrationsCanisterId = await getIntegrationsCanisterId();
    let emailService = actor (integrationsCanisterId.toText()) : EmailService.EmailService;

    try {
      let response = await (with cycles = maxEmailCost) emailService.send_email({
        from_username = fromUsername;
        to;
        cc;
        bcc;
        subject;
        html_body = htmlBody;
      });

      switch (response.result) {
        case (#Ok(_)) { return #ok };
        case (#Err(error)) { return #err(debug_show (error)) };
      };
    } catch (error) {
      return #err("Failed to send email: " # error.message());
    };
  };

  public func sendServiceEmail(
    fromUsername : Text,
    recipients : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult {
    await broadcastEmail(
      #Service,
      fromUsername,
      recipients.map(
        func(email) {
          {
            email;
            substitutions = null;
          };
        }
      ),
      subject,
      htmlBody,
    );
  };

  public func sendVerificationEmail(
    fromUsername : Text,
    recipients : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult {
    await broadcastEmail(
      #Verification,
      fromUsername,
      recipients.map(
        func(email) {
          {
            email;
            substitutions = null;
          };
        }
      ),
      subject,
      htmlBody,
    );
  };

  public func sendMarketingEmail(
    topicId : Nat,
    fromUsername : Text,
    recipients : [BroadcastEmailRecipient],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult {
    await broadcastEmail(
      #Marketing({ topic_id = Nat32.fromNat(topicId) }),
      fromUsername,
      recipients,
      subject,
      htmlBody,
    );
  };

  public func sendCalendarEvent(fromUsername : Text, event : CalendarEvent) : async SendResult {
    let maxEmailCost = 50_000_000_000; // 50B CYCLES

    let currentBalance = Cycles.balance();

    if (currentBalance < maxEmailCost) {
      return #err("Not enough cycles to send calendar event email");
    };

    let integrationsCanisterId = await getIntegrationsCanisterId();
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
        organizer = event.organizer;
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

  public func getIntegrationsCanisterId() : async Principal {
    switch (Prim.envVar<system>("INTEGRATIONS_CANISTER_ID")) {
      case (null) {
        Runtime.trap("INTEGRATIONS_CANISTER_ID environment variable is not set");
      };
      case (?integrationsCanisterId) {
        Principal.fromText(integrationsCanisterId);
      };
    };
  };

  func broadcastEmail(
    subType : EmailService.BroadcastEmailType,
    fromUsername : Text,
    recipients : [BroadcastEmailRecipient],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult {
    // TODO: This needs to be calculated here based om the number of recipients and body size
    let maxEmailCost = 50_000_000_000; // 50B CYCLES

    let currentBalance = Cycles.balance();

    if (currentBalance < maxEmailCost) {
      return #err("Not enough cycles to send email");
    };

    let integrationsCanisterId = await getIntegrationsCanisterId();
    let emailService = actor (integrationsCanisterId.toText()) : EmailService.EmailService;

    try {
      let response = await (with cycles = maxEmailCost) emailService.broadcast_email({
        sub_type = subType;
        from_username = fromUsername;
        recipients;
        subject;
        html_body = htmlBody;
      });

      switch (response.result) {
        case (#Ok(_)) { return #ok };
        case (#Err(error)) { return #err(debug_show (error)) };
      };
    } catch (error) {
      return #err(error.message());
    };
  };
};
