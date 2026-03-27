import Runtime "mo:core/Runtime";
import EmailClient "mo:caffeineai-email/emailClient";
import VerifiedEmails "verifiedEmails";

mixin (verifiedEmails : VerifiedEmails.State) {
  public shared ({ caller }) func _caffeineEmailVerify(email : Text) : async () {
    let integrationsCanisterId = await EmailClient.getIntegrationsCanisterId();
    if (integrationsCanisterId != caller) {
      Runtime.trap("Unauthorized caller");
    };
    VerifiedEmails.put(verifiedEmails, email);
  };
};
