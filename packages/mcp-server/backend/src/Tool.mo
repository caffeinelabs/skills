import Array "mo:core/Array";
import Float "mo:core/Float";
import Int "mo:core/Int";
import Json "mo:jayson/Json";

module {
  public type Json = Json.Json;

  public type Args = [(Text, Json)];

  // `#err` reaches the model as a tool error it can read and retry from.
  public type Result = { #ok : Json; #err : Text };

  // `run` gets the principal the user signed in with on the app, never the
  // anonymous one. `input` maps each argument name to a schema built with the
  // helpers below.
  public type Tool = {
    name : Text;
    description : Text;
    input : [(Text, Json)];
    required : [Text];
    readOnly : Bool;
    run : (caller : Principal, args : Args) -> async* Result;
  };

  func schema(typ : Text, description : Text) : Json {
    #Object([("type", #String(typ)), ("description", #String(description))]);
  };

  public func string(description : Text) : Json = schema("string", description);

  public func integer(description : Text) : Json = schema("integer", description);

  public func number(description : Text) : Json = schema("number", description);

  public func boolean(description : Text) : Json = schema("boolean", description);

  public func enumeration(values : [Text], description : Text) : Json {
    #Object([
      ("type", #String("string")),
      ("enum", #Array(values.map<Text, Json>(func v = #String(v)))),
      ("description", #String(description)),
    ]);
  };

  public func arrayOf(items : Json, description : Text) : Json {
    #Object([("type", #String("array")), ("items", items), ("description", #String(description))]);
  };

  public func objectOf(properties : [(Text, Json)], required : [Text], description : Text) : Json {
    #Object([
      ("type", #String("object")),
      ("properties", #Object(properties)),
      ("required", #Array(required.map<Text, Json>(func r = #String(r)))),
      ("description", #String(description)),
    ]);
  };

  // Also accepts JSON null, which `isNull` tells apart from a missing argument.
  public func nullable(base : Json) : Json {
    let #Object(fields) = base else return base;
    #Object(
      fields.map<(Text, Json), (Text, Json)>(
        func((k, v)) = switch (k, v) {
          case ("type", #String(t)) ("type", #Array([#String(t), #String("null")]));
          case _ (k, v);
        }
      )
    );
  };

  public func field(args : Args, name : Text) : ?Json {
    for ((k, v) in args.values()) {
      if (k == name) return ?v;
    };
    null;
  };

  public func isNull(args : Args, name : Text) : Bool {
    field(args, name) == ?#Null;
  };

  public func text(args : Args, name : Text) : ?Text {
    let ?#String(t) = field(args, name) else return null;
    ?t;
  };

  public func int(args : Args, name : Text) : ?Int {
    switch (field(args, name)) {
      case (?#Number(#Int(i))) ?i;
      case (?#Number(#Float(f))) if (Float.floor(f) == f and Float.abs(f) < 9e15) ?f.toInt() else null;
      case _ null;
    };
  };

  public func nat(args : Args, name : Text) : ?Nat {
    let ?i = int(args, name) else return null;
    if (i >= 0) ?i.toNat() else null;
  };

  public func float(args : Args, name : Text) : ?Float {
    switch (field(args, name)) {
      case (?#Number(n)) ?n.toFloat();
      case _ null;
    };
  };

  public func bool(args : Args, name : Text) : ?Bool {
    let ?#Bool(b) = field(args, name) else return null;
    ?b;
  };
};
