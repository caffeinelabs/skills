import Blob "mo:core/Blob";
import Char "mo:core/Char";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

// One recipe for every link token an app mints: a fresh 32-byte `raw_rand`
// seed per send call, then SHA-256(seed ‖ counter ‖ parts) per recipient,
// hex-encoded. Every token carries 256 bits and one send of many recipients
// costs one inter-canister call for the seed.
module {
  public func derive(seed : Blob, counter : Nat, parts : [Text]) : Text {
    let digest = Sha256.new(#sha256);
    Sha256.writeBlob(digest, seed);
    Sha256.writeBlob(digest, Text.encodeUtf8(Nat.toText(counter)));
    for (part in parts.values()) {
      Sha256.writeArray(digest, [0 : Nat8]);
      Sha256.writeBlob(digest, Text.encodeUtf8(part));
    };
    toHex(Sha256.sum(digest));
  };

  func toHex(blob : Blob) : Text {
    let digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];
    var hex = "";
    for (byte in blob.values()) {
      hex #= Char.toText(digits[(byte >> 4).toNat()]) # Char.toText(digits[(byte & 0x0F).toNat()]);
    };
    hex;
  };
};
