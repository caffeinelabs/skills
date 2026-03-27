import Iter "mo:core/Iter";
import Set "mo:core/Set";
import Text "mo:core/Text";

module {
  public type State = {
    verifiedEmails : Set.Set<Text>;
  };

  public func new() : State {
    {
      verifiedEmails = Set.empty<Text>();
    };
  };

  public func contains(state : State, email : Text) : Bool {
    state.verifiedEmails.contains(email);
  };

  public func put(state : State, email : Text) : () {
    state.verifiedEmails.add(email);
  };

  public func iter(state : State) : Iter.Iter<Text> {
    state.verifiedEmails.values();
  };

  public func size(state : State) : Nat {
    state.verifiedEmails.size();
  };

  public func intersect(state : State, emails : Set.Set<Text>) : Set.Set<Text> {
    state.verifiedEmails.intersection(emails);
  };
};
