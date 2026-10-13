import Array "mo:core/Array";
import Char "mo:core/Char";
import Cycles "mo:core/Cycles";
import Error "mo:core/Error";
import Int "mo:core/Int";
import Prim "mo:⛔";
import Random "mo:core/Random";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Time "mo:core/Time";
import Runtime "mo:core/Runtime";
import Map "mo:core/pure/Map";
import MailV2Api "mo:caffeine-integrations-mail-client/Apis/MailV2Api";
import { type Config } "mo:caffeine-integrations-mail-client/Config";
import { type MailV2BroadcastRecipient } "mo:caffeine-integrations-mail-client/Models/MailV2BroadcastRecipient";
import { type MailV2BroadcastResponse } "mo:caffeine-integrations-mail-client/Models/MailV2BroadcastResponse";
import MailV2BroadcastSubType "mo:caffeine-integrations-mail-client/Values/MailV2BroadcastSubType";

module {
  public type BroadcastEmailRecipient = {
    email : Text;
    substitutions : ?[(Text, Text)];
  };

  // A message header added to every copy of a broadcast, as (name, value).
  // The gateway accepts `List-Unsubscribe` only and fills `{{PLACEHOLDER}}`
  // substitutions in the value per recipient, like in the body.
  public type Header = (Text, Text);

  public type BroadcastKind = {
    #service;
    #verification;
    #marketing;
  };

  public type SendResult = {
    #ok;
    #err : Text;
  };

  // The error every send answers with while the platform has not injected
  // the gateway settings into the canister.
  public let gatewayNotConfigured = "The integrations gateway is not configured: INTEGRATIONS_GATEWAY_URL and INTEGRATIONS_GATEWAY_API_KEY are not set";

  // The gateway bills sends server-side via the API key, so attached
  // cycles only fund the HTTPS outcall itself (non-replicated; unused
  // cycles are refunded). 10B covers multi-megabyte bodies with margin.
  let maxOutcallCycles = 10_000_000_000;

  // The generated client's config for a call to the gateway, or null while
  // the canister has no gateway settings. Read on every send, never cached:
  // a settings update on a running canister must be visible to the next
  // send without a redeploy (planning/mail-integration-api-key, D12).
  public func gatewayConfig<system>() : ?Config {
    let ?apiKey = Prim.envVar<system>("INTEGRATIONS_GATEWAY_API_KEY") else return null;
    if (apiKey == "") return null;
    let ?url = Prim.envVar<system>("INTEGRATIONS_GATEWAY_URL") else return null;
    if (url == "") return null;
    ?{
      baseUrl = url;
      auth = ?#bearer(apiKey);
      max_response_bytes = ?(16_384 : Nat64);
      transform = null;
      is_replicated = ?false;
      // Engines report Cycles.balance() as 0 and subsidize outcalls, so
      // never attach more than the available balance.
      cycles = Nat.min(maxOutcallCycles, Cycles.balance());
    };
  };

  // One key per call: the round's time plus 128 random bits from `raw_rand`,
  // so two identical calls in one round still get distinct keys (the
  // instruction counter is the same for identical executions and cannot tell
  // them apart). The gateway scopes the key to this canister and to the
  // request payload, so it only ever matches a retry of this very request.
  func newIdempotencyKey() : async* Text {
    let nonce = await Random.blob();
    Int.toText(Time.now()) # ":" # hex(nonce, 16);
  };

  func hex(blob : Blob, bytes : Nat) : Text {
    let digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
    var out = "";
    var taken = 0;
    for (byte in blob.values()) {
      if (taken == bytes) return out;
      out #= Char.toText(digits[(byte >> 4).toNat()]) # Char.toText(digits[(byte & 0x0F).toNat()]);
      taken += 1;
    };
    out;
  };

  // A lost response (the outcall timed out or the subnet could not deliver
  // it) is retried once with the same key: the gateway replays the stored
  // response instead of sending and charging a second time. A rejection
  // from the gateway is final and is not retried.
  public func sendOnce(send : Text -> async* ()) : async* () {
    let idempotencyKey = await* newIdempotencyKey();
    try {
      await* send(idempotencyKey);
    } catch (error) {
      switch (Error.code(error)) {
        case (#system_transient) { await* send(idempotencyKey) };
        case _ { throw error };
      };
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
    let ?config = gatewayConfig<system>() else return #err(gatewayNotConfigured);
    try {
      // The 2xx body carries no signal beyond success (status is always
      // "sent"); every failure — gateway validation, auth, rate limit,
      // SES — arrives as a thrown error whose message includes the
      // parsed structured envelope from the gateway.
      await* sendOnce(
        func(idempotencyKey : Text) : async* () {
          ignore await* MailV2Api.mailV2Send(
            config,
            idempotencyKey,
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
        }
      );
      #ok;
    } catch (error) {
      #err("Failed to send email: " # error.message());
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
    await broadcast(#service, fromUsername, asBroadcastRecipients, subject, htmlBody, []);
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

  // A broadcast through the mail gateway with the recipients, body and
  // headers the caller prepared: the verification and marketing packages put
  // their tokens in the substitutions and their link templates in the body.
  // The kind is a label the gateway carries into its monitoring; the body
  // goes out as given.
  public func broadcast(
    kind : BroadcastKind,
    fromUsername : Text,
    recipients : [BroadcastEmailRecipient],
    subject : Text,
    htmlBody : Text,
    headers : [Header],
  ) : async SendResult {
    let ?config = gatewayConfig<system>() else return #err(gatewayNotConfigured);
    let subType = switch (kind) {
      case (#service) MailV2BroadcastSubType.service;
      case (#verification) MailV2BroadcastSubType.verification;
      case (#marketing) MailV2BroadcastSubType.marketing;
    };
    var response : ?MailV2BroadcastResponse = null;
    try {
      await* sendOnce(
        func(idempotencyKey : Text) : async* () {
          response := ?(await* MailV2Api.mailV2Broadcast(
            config,
            idempotencyKey,
            {
              subType;
              fromUsername;
              recipients = recipients.map(toGatewayRecipient);
              subject;
              htmlBody;
              attachments = [];
              headers = if (headers.size() == 0) null else ?headers.map(
                func((name, value) : Header) : { name : Text; value : Text } { { name; value } }
              );
            },
          ));
        }
      );
      broadcastResult(response ?? Runtime.unreachable());
    } catch (error) {
      #err(error.message());
    };
  };

  // #ok once the broadcast was accepted, even with some recipients failed
  // (the gateway emits per-recipient metrics); a broadcast where nothing
  // sent is a failure even if the gateway ever stops mapping it to a 5xx
  // itself.
  public func broadcastResult(response : MailV2BroadcastResponse) : SendResult {
    if (response.failures > 0 and response.emailsSent == 0) {
      return #err("Failed to send broadcast: " # (response.firstError ?? "all recipients failed"));
    };
    #ok;
  };

};
