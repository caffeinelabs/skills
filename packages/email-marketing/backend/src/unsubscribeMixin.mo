import Runtime "mo:core/Runtime";
import Nat32 "mo:core/Nat32";
import EmailClient "mo:caffeineai-email/emailClient";
import Subscribers "subscribers";

mixin (subscribers : Subscribers.State) {
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

  public shared ({ caller }) func _caffeineEmailUnsubscribeFromTopic(args : _CaffeineEmailUnsubscribeArgs) : async _CaffeineEmailUnsubscribeResult {
    let integrationsCanisterId = await EmailClient.getIntegrationsCanisterId();

    if (integrationsCanisterId != caller) {
      Runtime.trap("Unauthorized caller");
    };

    let topicId = args.topic_id.toNat();

    Subscribers.remove(subscribers, topicId, args.recipient_email);

    switch (Subscribers.getTopicName(subscribers, topicId)) {
      case (?topic) { #Ok({ topic_name = ?topic }) };
      case (null) { #Ok({ topic_name = null }) };
    };
  };
};
