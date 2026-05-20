import Iter "mo:core/Iter";
import Map "mo:core/Map";
import Set "mo:core/Set";
import Order "mo:core/Order";
import List "mo:core/List";
import Stack "mo:core/Stack";
import Queue "mo:core/Queue";

mixin () {

  module MapView {
    public func view<K, V>(
      self : Map.Map<K, V>,
      compare : (implicit : (K, K) -> Order.Order),
    ) : (ko : ?K, count : ?Nat) -> [(K, V)] = func(ko, count) {
      let entries = switch ko {
        case null { self.entries() };
        case (?k) { self.entriesFrom(k) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

  module SetView {
    public func view<K>(
      self : Set.Set<K>,
      compare : (implicit : (K, K) -> Order.Order),
    ) : (ko : ?K, count : ?Nat) -> [K] = func(ko, count) {
      let entries = switch ko {
        case null { self.values() };
        case (?k) { self.valuesFrom(k) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

  module ArrayView {
    public func view<V>(self : [V]) : (io : ?Nat, count : ?Nat) -> [V] = func(io, count) {
      let entries = switch io {
        case null { self.values() };
        case (?io) { self.values().drop(io) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

  module VarArrayView {
    public func view<V>(self : [var V]) : (io : ?Nat, count : ?Nat) -> [V] = func(io, count) {
      let entries = switch io {
        case null { self.values() };
        case (?io) { self.values().drop(io) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

  module ListView {
    public func view<V>(self : List.List<V>) : (io : ?Nat, count : ?Nat) -> [V] = func(io, count) {
      let entries = switch io {
        case null { self.values() };
        case (?io) { self.values().drop(io) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

  module StackView {
    public func view<V>(self : Stack.Stack<V>) : (io : ?Nat, count : ?Nat) -> [V] = func(io, count) {
      let entries = switch io {
        case null { self.values() };
        case (?io) { self.values().drop(io) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

  module QueueView {
    public func view<V>(self : Queue.Queue<V>) : (io : ?Nat, count : ?Nat) -> [V] = func(io, count) {
      let entries = switch io {
        case null { self.values() };
        case (?io) { self.values().drop(io) };
      };
      switch count {
        case null { entries.toArray() };
        case (?c) { entries.take(c).toArray() };
      };
    };
  };

};
