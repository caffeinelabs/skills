/// In-memory entity registry. The mixin builds one from the `entities`
/// array at actor init (and again on every upgrade — entity decls capture
/// closures over actor state and can't be persisted).

import Iter   "mo:core/Iter";
import Map    "mo:core/Map";
import Text   "mo:core/Text";
import Entity "Entity";
import Schema "Schema";

module {

  public type Registry = { byName : Map.Map<Text, Entity.Decl> };

  public func build(decls : [Entity.Decl]) : Registry {
    let byName = Map.empty<Text, Entity.Decl>();
    for (d in decls.values()) { byName.add(d.name, d) };
    { byName }
  };

  public func lookup(r : Registry, name : Text) : ?Entity.Decl =
    r.byName.get(name);

  /// Project the registry into the schema document `schema()` returns.
  /// `Entity.Decl` carries an extra `rows` closure that `EntityDecl` lacks;
  /// the map drops it.
  public func schema(r : Registry) : Schema.Document = {
    entities = r.byName.values().map(func (d : Entity.Decl) : Schema.EntityDecl = {
      name = d.name; typeName = d.typeName; primaryKey = d.primaryKey; fields = d.fields;
    }).toArray()
  };

};
