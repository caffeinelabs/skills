/// Implicit instance: `Blob -> Value`. `Value` has no `#blob` arm, so a Blob
/// renders through `Text`: valid UTF-8 decodes to the readable string — an
/// ExternalBlob object-storage reference is UTF-8 ("!caf!sha256:…"), so it
/// stays queryable and returnable as text — and non-UTF-8 binary renders as a
/// size placeholder. Without this instance a record carrying a `Blob` field
/// cannot auto-derive via `Entity.new`: it falls back to `Entity.manual` (whose
/// default `toRow` is empty), collapsing blob-bearing entities to empty rows.
///
/// A binary `#blob` Value arm (letting non-UTF-8 blobs carry their raw bytes
/// instead of a placeholder) is deferred to its own change.

import Text  "mo:core/Text";
import Nat   "mo:core/Nat";
import Types "Types";

module {
  public func _toRow(self : Blob) : Types.Value =
    switch (self.decodeUtf8()) {
      case (?t) #text t;
      case null #text ("<blob:" # self.size().toText() # " bytes>");
    };
};
