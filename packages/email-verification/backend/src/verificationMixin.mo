import Time "mo:core/Time";
import VerificationTokens "verificationTokens";
import VerifiedEmails "verifiedEmails";

mixin (verifiedEmails : VerifiedEmails.State, verificationTokens : VerificationTokens.State) {
  // Called by the app's own frontend from the verification landing page. The
  // token is the only credential: anyone holding a valid one, the anonymous
  // principal included, confirms the address it was sent to. Returns it.
  public shared func _caffeineEmailConfirmVerification(token : Text) : async { #ok : Text; #err : Text } {
    switch (VerificationTokens.consume(verificationTokens, token, Time.now())) {
      case (?email) {
        VerifiedEmails.put(verifiedEmails, email);
        #ok(email);
      };
      case null {
        #err("This verification link is invalid or has expired");
      };
    };
  };
};
