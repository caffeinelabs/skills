import Array "mo:core/Array";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Prim "mo:⛔";
import Principal "mo:core/Principal";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import Runtime "mo:core/Runtime";
import Map "mo:core/pure/Map";
import MailV2Api "mo:caffeine-integrations-mail-client/Apis/MailV2Api";
import { type Config } "mo:caffeine-integrations-mail-client/Config";
import { type MailV2BroadcastRecipient } "mo:caffeine-integrations-mail-client/Models/MailV2BroadcastRecipient";
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

  // Read on every send, never cached: a settings update on a running
  // canister must be visible to the next send without a redeploy
  // (planning/mail-integration-api-key, D12).
  func gatewayEnv<system>() : ?{ url : Text; apiKey : Text } {
    let ?apiKey = Prim.envVar<system>("INTEGRATIONS_GATEWAY_API_KEY") else return null;
    if (apiKey == "") return null;
    let ?url = Prim.envVar<system>("INTEGRATIONS_GATEWAY_URL") else return null;
    if (url == "") return null;
    ?{ url; apiKey };
  };

  // The gateway bills sends server-side via the API key, so attached
  // cycles only fund the HTTPS outcall itself (non-replicated; unused
  // cycles are refunded). 10B covers multi-megabyte bodies with margin.
  let maxOutcallCycles = 10_000_000_000;

  func gatewayConfig(env : { url : Text; apiKey : Text }, cycles : Nat) : Config {
    {
      baseUrl = env.url;
      auth = ?#bearer(env.apiKey);
      max_response_bytes = ?(16_384 : Nat64);
      transform = null;
      is_replicated = ?false;
      cycles;
    };
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

    switch (gatewayEnv<system>()) {
      case (?env) {
        // Engines report Cycles.balance() as 0 and subsidize outcalls, so
        // never attach more than the available balance.
        let cycles = Nat.min(maxOutcallCycles, Cycles.balance());
        try {
          // The 2xx body carries no signal beyond success (status is the
          // single-value enum "sent"); every failure — gateway validation,
          // auth, rate limit, SES — arrives as a thrown error whose message
          // includes the parsed structured envelope from the gateway.
          let { status = _ } = await* MailV2Api.mailV2Send(
            gatewayConfig(env, cycles),
            "",
            {
              fromUsername;
              to;
              cc;
              bcc;
              subject;
              htmlBody;
              attachments = [];
            },
          );
          #ok;
        } catch (error) {
          #err("Failed to send email: " # error.message());
        };
      };
      case null {
        if (Cycles.balance() < maxEmailCost) {
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
    };
  };

  public func sendServiceEmail(
    fromUsername : Text,
    recipients : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult {
    let asBroadcastRecipients = recipients.map(
      func(email) {
        {
          email;
          substitutions = null;
        };
      }
    );

    switch (gatewayEnv<system>()) {
      case (?env) {
        await gatewayBroadcast(env, fromUsername, asBroadcastRecipients, subject, htmlBody);
      };
      case null {
        await broadcastEmail(#Service, fromUsername, asBroadcastRecipients, subject, htmlBody);
      };
    };
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
    Principal.fromText(
      Prim.envVar<system>("INTEGRATIONS_CANISTER_ID")
        ?? Runtime.trap("INTEGRATIONS_CANISTER_ID environment variable is not set")
    );
  };

  func toGatewayRecipient(recipient : BroadcastEmailRecipient) : MailV2BroadcastRecipient {
    {
      email = recipient.email;
      substitutions = switch (recipient.substitutions) {
        case (?substitutions) ?Map.fromIter(substitutions.values(), Text.compare);
        case null null;
      };
    };
  };

  func gatewayBroadcast(
    env : { url : Text; apiKey : Text },
    fromUsername : Text,
    recipients : [BroadcastEmailRecipient],
    subject : Text,
    htmlBody : Text,
  ) : async SendResult {
    // Same engine consideration as sendRawEmail: attach at most the
    // available balance, never require it upfront.
    let cycles = Nat.min(maxOutcallCycles, Cycles.balance());

    try {
      let response = await* MailV2Api.mailV2Broadcast(
        gatewayConfig(env, cycles),
        "",
        {
          subType = #service;
          fromUsername;
          recipients = recipients.map(toGatewayRecipient);
          subject;
          htmlBody;
          attachments = [];
        },
      );
      // Partial failure keeps the transport path's contract (#ok once the
      // broadcast was accepted; the gateway already emits per-recipient
      // metrics), but a broadcast where nothing sent is a failure even if
      // the gateway ever stops mapping it to a 5xx itself.
      if (response.failures > 0 and response.emailsSent == 0) {
        return #err(
          "Failed to send broadcast: " # (response.firstError ?? "all recipients failed")
        );
      };
      #ok;
    } catch (error) {
      #err(error.message());
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
