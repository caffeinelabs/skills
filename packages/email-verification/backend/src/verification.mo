import Array "mo:core/Array";
import Random "mo:core/Random";
import Text "mo:core/Text";
import Time "mo:core/Time";
import EmailClient "mo:caffeineai-email/emailClient";
import Tokens "tokens";
import VerificationTokens "verificationTokens";

// Sends verification mail with a link to the app's own frontend: the app
// canister mints and stores the token, the gateway fills it in per recipient
// and `{{APP_DOMAIN}}` on send.
module {
  public let placeholder = "{{VERIFICATION_URL}}";

  public let linkTemplate = "https://{{APP_DOMAIN}}/verify-email?token={{VERIFICATION_TOKEN}}";

  public func sendVerificationEmail(
    tokens : VerificationTokens.State,
    fromUsername : Text,
    recipients : [Text],
    subject : Text,
    htmlBody : Text,
  ) : async EmailClient.SendResult {
    if (not htmlBody.contains(#text placeholder)) {
      return #err("The email body must contain the " # placeholder # " placeholder");
    };
    let now = Time.now();
    VerificationTokens.prune(tokens, now);
    let seed = await Random.blob();
    var counter = 0;
    let prepared = recipients.map(
      func(email : Text) : EmailClient.BroadcastEmailRecipient {
        let token = Tokens.derive(seed, counter, [email]);
        counter += 1;
        VerificationTokens.add(tokens, token, email, now);
        { email; substitutions = ?[("VERIFICATION_TOKEN", token)] };
      }
    );
    await EmailClient.broadcast(
      #verification,
      fromUsername,
      prepared,
      subject,
      htmlBody.replace(#text placeholder, linkTemplate),
      [],
    );
  };
};
