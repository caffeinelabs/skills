/// An app-defined `?Text` instance mapping `null` to `""`. Imported only by
/// `OptionOverride.test.mo`, to prove a more specific instance in scope wins
/// over `Entity`'s generic `?T` one.

import Types "../../src/Types";

module {
  public func _toRow(self : ?Text) : Types.Value = switch self {
    case null   { #text("") };
    case (?t)   { #text(t) };
  };
};
