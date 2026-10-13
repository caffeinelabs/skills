import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

// Unsubscribe links: one token per (subscriber, topic), minted the first time
// the subscriber is mailed on that topic and stable across sends so the link
// in older mail keeps working. Dropped when the token is used.
module {
  public type Subscription = {
    email : Text;
    topicId : Nat;
  };

  public type State = {
    byToken : Map.Map<Text, Subscription>;
    bySubscription : Map.Map<Text, Text>;
  };

  public func new() : State {
    {
      byToken = Map.empty<Text, Subscription>();
      bySubscription = Map.empty<Text, Text>();
    };
  };

  func subscriptionKey(email : Text, topicId : Nat) : Text {
    Nat.toText(topicId) # ":" # email;
  };

  public func get(state : State, email : Text, topicId : Nat) : ?Text {
    state.bySubscription.get(subscriptionKey(email, topicId));
  };

  public func put(state : State, token : Text, email : Text, topicId : Nat) {
    state.byToken.add(token, { email; topicId });
    state.bySubscription.add(subscriptionKey(email, topicId), token);
  };

  public func lookup(state : State, token : Text) : ?Subscription {
    state.byToken.get(token);
  };

  public func remove(state : State, email : Text, topicId : Nat) {
    switch (get(state, email, topicId)) {
      case (?token) {
        state.byToken.remove(token);
        state.bySubscription.remove(subscriptionKey(email, topicId));
      };
      case null {};
    };
  };

  public func size(state : State) : Nat {
    state.byToken.size();
  };
};
