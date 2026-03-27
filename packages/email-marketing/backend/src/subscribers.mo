import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Set "mo:core/Set";
import Text "mo:core/Text";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";

module {
  public type State = {
    topics : Map.Map<Nat, TopicRecord>;
    topicsByName : Map.Map<Text, Nat>;
    var idGen : Nat;
  };

  type TopicRecord = {
    var name : Text;
    subscribers : Set.Set<Text>;
  };

  public type Topic = {
    id : Nat;
    name : Text;
  };

  public func new(topics : [Text]) : State {
    let state = {
      topics = Map.empty<Nat, TopicRecord>();
      topicsByName = Map.empty<Text, Nat>();
      var idGen = 0;
    };

    for (name in topics.vals()) {
      ignore addTopic(state, name);
    };

    state;
  };

  // Add a topic if it doesn't exist and return its ID or the existing topic ID.
  public func addTopic(state : State, name : Text) : Nat {
    switch (state.topicsByName.get(name)) {
      case (?topicId) { topicId };
      case (_) {
        let newId = state.idGen;
        state.idGen += 1;
        let record = {
          var name;
          subscribers = Set.empty<Text>();
        };
        state.topics.add(newId, record);
        state.topicsByName.add(name, newId);
        newId;
      };
    };
  };

  // Rename a topic. Returns false if a topic with the new name already exists or the topic ID does not exist.
  public func renameTopic(state : State, topicId : Nat, newName : Text) : Bool {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        switch (state.topicsByName.get(newName)) {
          case (?_) { false };
          case (_) {
            state.topicsByName.remove(topicRecord.name);
            topicRecord.name := newName;
            state.topicsByName.add(newName, topicId);
            true;
          };
        };
      };
      case (_) { false };
    };
  };

  // Remove a topic. Also removes all subscribers from that topic.
  public func removeTopic(state : State, topicId : Nat) {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        state.topicsByName.remove(topicRecord.name);
        state.topics.remove(topicId);
      };
      case (_) {};
    };
  };

  // List all topics (without subscribers).
  public func listTopics(state : State) : [Topic] {
    state.topics.toArray().map(
      func((id, record)) { { id; name = record.name } }
    );
  };

  // Get a topic ID by name
  public func getTopicId(state : State, name : Text) : ?Nat {
    state.topicsByName.get(name);
  };

  // Get a topic name by ID
  public func getTopicName(state : State, topicId : Nat) : ?Text {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) { ?topicRecord.name };
      case (_) { null };
    };
  };

  // Add a subscriber to a topic. Returns false if the topic doesn't exist
  public func add(state : State, topicId : Nat, email : Text) : Bool {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        topicRecord.subscribers.add(email);
        true;
      };
      case (_) { false };
    };
  };

  // Remove a subscriber from a topic
  public func remove(state : State, topicId : Nat, email : Text) {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        topicRecord.subscribers.remove(email);
      };
      case (_) {};
    };
  };

  // Remove a subscriber from all topics
  public func removeFromAllTopics(state : State, email : Text) {
    for (topicRecord in state.topics.values()) {
      topicRecord.subscribers.remove(email);
    };
  };

  // List all subscribers alongside their verification status for a given topic. Returns null if the topic doesn't exist.
  public func list(state : State, verifiedEmails : VerifiedEmails.State, topicId : Nat) : ?[(Text, Bool)] {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        ?topicRecord.subscribers.values().toArray().map(
          func(email) {
            let isVerified = VerifiedEmails.contains(verifiedEmails, email);
            (email, isVerified);
          }
        );
      };
      case (_) { null };
    };
  };

  // List all verified subscribers for a given topic. Returns null if the topic doesn't exist.
  public func verified(state : State, verifiedEmails : VerifiedEmails.State, topicId : Nat) : ?[Text] {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        ?topicRecord.subscribers.toArray().filter(
          func(email) {
            VerifiedEmails.contains(verifiedEmails, email);
          }
        );
      };
      case (_) { null };
    };
  };

  // Return whether a subscriber is subscribed to a topic
  public func isSubscribed(state : State, topicId : Nat, email : Text) : Bool {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        topicRecord.subscribers.contains(email);
      };
      case (_) { false };
    };
  };

  // List all topics a subscriber is subscribed to.
  public func listTopicsForSubscriber(state : State, email : Text) : [Topic] {
    state.topics.toArray().filter(
      func((_, record)) {
        record.subscribers.contains(email);
      }
    ).map(
      func((id, record)) { { id; name = record.name } }
    );
  };

  // Returns the count of subscribers for a given topic
  public func count(state : State, topicId : Nat) : Nat {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) { topicRecord.subscribers.size() };
      case (_) { 0 };
    };
  };

  // Returns the count of verified subscribers for a given topic
  public func verifiedCount(state : State, verifiedEmails : VerifiedEmails.State, topicId : Nat) : Nat {
    switch (state.topics.get(topicId)) {
      case (?topicRecord) {
        VerifiedEmails.intersect(verifiedEmails, topicRecord.subscribers).size();
      };
      case (_) { 0 };
    };
  };
};
