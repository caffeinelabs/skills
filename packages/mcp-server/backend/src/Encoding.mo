import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Char "mo:core/Char";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Text "mo:core/Text";
import Sha256 "mo:sha2/Sha256";

module {
  let hexDigits : [Char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

  public func hex(blob : Blob) : Text {
    var out = "";
    for (byte in blob.values()) {
      out #= hexDigits[(byte >> 4).toNat()].toText() # hexDigits[(byte & 0x0F).toNat()].toText();
    };
    out;
  };

  public func sha256(blob : Blob) : Blob {
    Sha256.fromBlob(#sha256, blob);
  };

  public func sha256Hex(text : Text) : Text {
    hex(sha256(text.encodeUtf8()));
  };

  // Unpadded, as PKCE (RFC 7636) requires.
  public func base64Url(blob : Blob) : Text {
    let digits = Text.toArray("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_");
    let bytes = blob.toArray();
    let n = bytes.size();
    var out = "";
    var i = 0;
    func digit(word : Nat32, shift : Nat32) : Text {
      digits[((word >> shift) & 0x3F).toNat()].toText();
    };
    while (i < n) {
      let b0 = bytes[i].toNat32();
      let b1 = if (i + 1 < n) bytes[i + 1].toNat32() else (0 : Nat32);
      let b2 = if (i + 2 < n) bytes[i + 2].toNat32() else (0 : Nat32);
      let word = (b0 << 16) | (b1 << 8) | b2;
      out #= digit(word, 18) # digit(word, 12);
      if (i + 1 < n) out #= digit(word, 6);
      if (i + 2 < n) out #= digit(word, 0);
      i += 3;
    };
    out;
  };

  func hexValue(c : Char) : ?Nat8 {
    let code = c.toNat32();
    if (code >= 48 and code <= 57) return ?(code - 48).toNat().toNat8();
    if (code >= 97 and code <= 102) return ?(code - 87).toNat().toNat8();
    if (code >= 65 and code <= 70) return ?(code - 55).toNat().toNat8();
    null;
  };

  // application/x-www-form-urlencoded value: `+` is a space, `%XX` a byte.
  public func percentDecode(text : Text) : ?Text {
    let bytes = List.empty<Nat8>();
    let chars = text.chars();
    label scan loop {
      let ?c = chars.next() else break scan;
      if (c == '+') {
        bytes.add(32 : Nat8);
      } else if (c == '%') {
        let ?h = chars.next() else return null;
        let ?l = chars.next() else return null;
        let ?high = hexValue(h) else return null;
        let ?low = hexValue(l) else return null;
        bytes.add(high * 16 + low);
      } else {
        for (b in c.toText().encodeUtf8().values()) bytes.add(b);
      };
    };
    bytes.toArray().toBlob().decodeUtf8();
  };

  public func formDecode(body : Text) : [(Text, Text)] {
    let pairs = List.empty<(Text, Text)>();
    for (part in body.split(#char '&')) {
      if (part != "") {
        let kv = part.split(#char '=');
        let rawKey = kv.next() ?? "";
        let rawValue = kv.join("=");
        switch (percentDecode(rawKey), percentDecode(rawValue)) {
          case (?k, ?v) pairs.add((k, v));
          case _ {};
        };
      };
    };
    pairs.toArray();
  };
};
