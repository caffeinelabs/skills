import Runtime "mo:core/Runtime";
import Nat32 "mo:core/Nat32";
import Prim "mo:⛔";
import Principal "mo:core/Principal";
import Subscribers "subscribers";
import UnsubscribeTokens "unsubscribeTokens";

mixin (subscribers : Subscribers.State, unsubscribeTokens : UnsubscribeTokens.State) {
  type _CaffeineEmailUnsubscribeArgs = {
    topic_id : Nat32;
    recipient_email : Text;
  };

  type _CaffeineEmailUnsubscribeResult = {
    #Ok : _UnsubscribeSuccess;
    #Err : _UnsubscribeError;
  };

  type _UnsubscribeSuccess = {
    topic_name : ?Text;
  };

  type _UnsubscribeError = {};

  // Legacy callback of the integrations transport canister, kept so links in
  // marketing mail sent before the app moved to the gateway keep working.
  public shared ({ caller }) func _caffeineEmailUnsubscribeFromTopic(args : _CaffeineEmailUnsubscribeArgs) : async _CaffeineEmailUnsubscribeResult {
    let transportCanisterId = Principal.fromText(
      Prim.envVar<system>("INTEGRATIONS_CANISTER_ID")
        ?? Runtime.trap("INTEGRATIONS_CANISTER_ID environment variable is not set")
    );
    if (transportCanisterId != caller) {
      Runtime.trap("Unauthorized caller");
    };

    let topicId = args.topic_id.toNat();

    Subscribers.remove(subscribers, unsubscribeTokens, topicId, args.recipient_email);

    switch (Subscribers.getTopicName(subscribers, topicId)) {
      case (?topic) { #Ok({ topic_name = ?topic }) };
      case (null) { #Ok({ topic_name = null }) };
    };
  };

  // Called by the app's own frontend from the unsubscribe landing page. The
  // token is the only credential: anyone holding a valid one, the anonymous
  // principal included, unsubscribes the address from the topic it was
  // minted for. Returns the topic's name when the topic still exists.
  public shared func _caffeineEmailUnsubscribe(token : Text) : async { #ok : { topic : ?Text }; #err : Text } {
    switch (UnsubscribeTokens.lookup(unsubscribeTokens, token)) {
      case (?{ email; topicId }) {
        if (not Subscribers.isSubscribed(subscribers, topicId, email)) {
          UnsubscribeTokens.remove(unsubscribeTokens, email, topicId);
          return #err("This unsubscribe link is invalid or was already used");
        };
        Subscribers.remove(subscribers, unsubscribeTokens, topicId, email);
        #ok({ topic = Subscribers.getTopicName(subscribers, topicId) });
      };
      case null {
        #err("This unsubscribe link is invalid or was already used");
      };
    };
  };
};
