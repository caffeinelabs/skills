import { test } "mo:test";
import Subscribers "../src/subscribers";
import UnsubscribeTokens "../src/unsubscribeTokens";

func subscribed() : (Subscribers.State, UnsubscribeTokens.State, Nat) {
  let subscribers = Subscribers.new(["news"]);
  let tokens = UnsubscribeTokens.new();
  let ?topicId = Subscribers.getTopicId(subscribers, "news") else return (subscribers, tokens, 0);
  ignore Subscribers.add(subscribers, topicId, "alice@example.com");
  UnsubscribeTokens.put(tokens, "tok-alice", "alice@example.com", topicId);
  (subscribers, tokens, topicId);
};

test("removing a subscriber retires their unsubscribe token", func() {
  let (subscribers, tokens, topicId) = subscribed();
  Subscribers.remove(subscribers, tokens, topicId, "alice@example.com");
  assert not Subscribers.isSubscribed(subscribers, topicId, "alice@example.com");
  assert UnsubscribeTokens.lookup(tokens, "tok-alice") == null;
  assert UnsubscribeTokens.get(tokens, "alice@example.com", topicId) == null;
});

test("a re-subscribed address starts without a token, so the old link stays dead", func() {
  let (subscribers, tokens, topicId) = subscribed();
  Subscribers.remove(subscribers, tokens, topicId, "alice@example.com");
  ignore Subscribers.add(subscribers, topicId, "alice@example.com");
  assert Subscribers.isSubscribed(subscribers, topicId, "alice@example.com");
  assert UnsubscribeTokens.get(tokens, "alice@example.com", topicId) == null;
  assert UnsubscribeTokens.lookup(tokens, "tok-alice") == null;
});

test("removing a topic retires the tokens of its subscribers only", func() {
  let (subscribers, tokens, topicId) = subscribed();
  let other = Subscribers.addTopic(subscribers, "offers");
  ignore Subscribers.add(subscribers, other, "alice@example.com");
  UnsubscribeTokens.put(tokens, "tok-offers", "alice@example.com", other);
  Subscribers.removeTopic(subscribers, tokens, topicId);
  assert UnsubscribeTokens.lookup(tokens, "tok-alice") == null;
  assert UnsubscribeTokens.lookup(tokens, "tok-offers") == ?{ email = "alice@example.com"; topicId = other };
});

test("removing an address from all topics retires every token it holds", func() {
  let (subscribers, tokens, topicId) = subscribed();
  let other = Subscribers.addTopic(subscribers, "offers");
  ignore Subscribers.add(subscribers, other, "alice@example.com");
  UnsubscribeTokens.put(tokens, "tok-offers", "alice@example.com", other);
  Subscribers.removeFromAllTopics(subscribers, tokens, "alice@example.com");
  assert not Subscribers.isSubscribed(subscribers, topicId, "alice@example.com");
  assert not Subscribers.isSubscribed(subscribers, other, "alice@example.com");
  assert UnsubscribeTokens.size(tokens) == 0;
});
