import { test } "mo:test";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";
import Marketing "../src/marketing";
import Subscribers "../src/subscribers";

func topic() : (Subscribers.State, VerifiedEmails.State, Nat) {
  let subscribers = Subscribers.new(["news"]);
  let verified = VerifiedEmails.new();
  let ?topicId = Subscribers.getTopicId(subscribers, "news") else return (subscribers, verified, 0);
  ignore Subscribers.add(subscribers, topicId, "alice@example.com");
  VerifiedEmails.put(verified, "alice@example.com");
  ignore Subscribers.add(subscribers, topicId, "bob@example.com");
  VerifiedEmails.put(verified, "bob@example.com");
  ignore Subscribers.add(subscribers, topicId, "carol@example.com");
  VerifiedEmails.put(verified, "dave@example.com");
  (subscribers, verified, topicId);
};

test("the topic's recipients are its verified subscribers", func() {
  let (subscribers, verified, topicId) = topic();
  assert Marketing.recipients(subscribers, verified, topicId, null) == ?["alice@example.com", "bob@example.com"];
});

test("an explicit list is cut down to the topic's verified subscribers", func() {
  let (subscribers, verified, topicId) = topic();
  let chosen = ["bob@example.com", "carol@example.com", "dave@example.com", "erin@example.com"];
  assert Marketing.recipients(subscribers, verified, topicId, ?chosen) == ?["bob@example.com"];
  assert Marketing.recipients(subscribers, verified, topicId, ?["erin@example.com"]) == ?[];
});

test("a topic that does not exist has no recipients", func() {
  let (subscribers, verified, topicId) = topic();
  assert Marketing.recipients(subscribers, verified, topicId + 1, null) == null;
});
