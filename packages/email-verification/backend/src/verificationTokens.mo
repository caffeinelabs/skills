import List "mo:core/List";
import Map "mo:core/Map";
import Text "mo:core/Text";
import Time "mo:core/Time";

// Pending verification links: the token in the mail, the address it was
// sent to, and when. A token is single use and expires after 24 hours.
module {
  public type Pending = {
    email : Text;
    createdAt : Time.Time;
  };

  public type State = {
    tokens : Map.Map<Text, Pending>;
  };

  // 24 hours in nanoseconds.
  let ttl : Int = 86_400_000_000_000;

  public func new() : State {
    {
      tokens = Map.empty<Text, Pending>();
    };
  };

  public func add(state : State, token : Text, email : Text, now : Time.Time) {
    state.tokens.add(token, { email; createdAt = now });
  };

  // Removes the token whether or not it is still valid, so a link works once.
  public func consume(state : State, token : Text, now : Time.Time) : ?Text {
    let ?pending = state.tokens.get(token) else return null;
    state.tokens.remove(token);
    if (now - pending.createdAt > ttl) {
      return null;
    };
    ?pending.email;
  };

  public func prune(state : State, now : Time.Time) {
    let expired = List.empty<Text>();
    for ((token, pending) in state.tokens.entries()) {
      if (now - pending.createdAt > ttl) {
        expired.add(token);
      };
    };
    for (token in expired.values()) {
      state.tokens.remove(token);
    };
  };

  public func size(state : State) : Nat {
    state.tokens.size();
  };
};
