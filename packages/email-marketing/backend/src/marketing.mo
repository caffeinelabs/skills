import Array "mo:core/Array";
import Random "mo:core/Random";
import Text "mo:core/Text";
import EmailClient "mo:caffeineai-email/emailClient";
import Tokens "mo:caffeineai-email-verification/tokens";
import VerifiedEmails "mo:caffeineai-email-verification/verifiedEmails";
import Subscribers "subscribers";
import UnsubscribeTokens "unsubscribeTokens";

// Sends marketing mail. The unsubscribe link lands on the app's own
// frontend, in the body and in the List-Unsubscribe header: the app canister
// mints and stores the token per (subscriber, topic), the gateway fills it
// in per recipient and `{{APP_DOMAIN}}` on send. Mail goes to verified
// subscribers of the topic only: the unsubscribe handlers refuse an address
// that is not subscribed, so a copy to anyone else would carry a link that
// never works.
module {
  public let placeholder = "{{UNSUBSCRIBE_URL}}";

  public let linkTemplate = "https://{{APP_DOMAIN}}/unsubscribe?token={{UNSUBSCRIBE_TOKEN}}";

  // The verified subscribers of the topic, or those of them in `among` when
  // it is given. Null when the topic does not exist.
  public func recipients(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    topicId : Nat,
    among : ?[Text],
  ) : ?[Text] {
    let ?verified = Subscribers.verified(subscribers, verifiedEmails, topicId) else return null;
    switch (among) {
      case null ?verified;
      case (?chosen) ?verified.filter(func(email) = chosen.any(func(wanted) = wanted == email));
    };
  };

  // Sends to every verified subscriber of the topic. `personalise` returns the
  // substitutions for one address, such as `[("NAME", name)]`, or `[]`.
  public func sendMarketingEmail(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    tokens : UnsubscribeTokens.State,
    topicId : Nat,
    fromUsername : Text,
    subject : Text,
    htmlBody : Text,
    personalise : Text -> [(Text, Text)],
  ) : async EmailClient.SendResult {
    await send(subscribers, verifiedEmails, tokens, topicId, null, fromUsername, subject, htmlBody, personalise);
  };

  // Sends to the given addresses that are verified subscribers of the topic;
  // the others are left out, since their unsubscribe link could not work.
  public func sendMarketingEmailTo(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    tokens : UnsubscribeTokens.State,
    topicId : Nat,
    fromUsername : Text,
    emails : [Text],
    subject : Text,
    htmlBody : Text,
    personalise : Text -> [(Text, Text)],
  ) : async EmailClient.SendResult {
    await send(subscribers, verifiedEmails, tokens, topicId, ?emails, fromUsername, subject, htmlBody, personalise);
  };

  func send(
    subscribers : Subscribers.State,
    verifiedEmails : VerifiedEmails.State,
    tokens : UnsubscribeTokens.State,
    topicId : Nat,
    among : ?[Text],
    fromUsername : Text,
    subject : Text,
    htmlBody : Text,
    personalise : Text -> [(Text, Text)],
  ) : async EmailClient.SendResult {
    let ?emails = recipients(subscribers, verifiedEmails, topicId, among) else {
      return #err("Topic " # debug_show (topicId) # " does not exist");
    };
    if (emails.size() == 0) {
      return #err("Topic " # debug_show (topicId) # " has no verified subscribers to send to");
    };
    let recipientList = emails.map(
      func(email : Text) : EmailClient.BroadcastEmailRecipient {
        let substitutions = personalise(email);
        { email; substitutions = if (substitutions.size() == 0) null else ?substitutions };
      }
    );
    let bodyWithPlaceholder = if (htmlBody.contains(#text placeholder)) {
      htmlBody;
    } else {
      htmlBody # "<br><br><a href=\"" # placeholder # "\">Unsubscribe</a>";
    };
    let seed = await Random.blob();
    var counter = 0;
    let prepared = recipientList.map(
      func(recipient : EmailClient.BroadcastEmailRecipient) : EmailClient.BroadcastEmailRecipient {
        let token = switch (UnsubscribeTokens.get(tokens, recipient.email, topicId)) {
          case (?existing) existing;
          case null {
            let minted = Tokens.derive(seed, counter, [recipient.email, debug_show (topicId)]);
            counter += 1;
            UnsubscribeTokens.put(tokens, minted, recipient.email, topicId);
            minted;
          };
        };
        {
          email = recipient.email;
          substitutions = ?(recipient.substitutions ?? []).concat([("UNSUBSCRIBE_TOKEN", token)]);
        };
      }
    );
    await EmailClient.broadcast(
      #marketing,
      fromUsername,
      prepared,
      subject,
      bodyWithPlaceholder.replace(#text placeholder, linkTemplate),
      [("List-Unsubscribe", "<" # linkTemplate # ">")],
    );
  };
};
