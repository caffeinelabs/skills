/// The `Expose` mixin. `include OQL.Expose({ entities = [...]; ... })`
/// adds four public functions to the actor:
///
///   schema(token : ?Text)                : async Text     — JSON schema document
///   execute(qJson : Text, token : ?Text) : async Result   — typed Candid result
///   oqlMintToken(owner : ?Principal, ttlSeconds : ?Nat) : async Text — controller-only update
///   oqlRevokeToken(token : Text)         : async Bool     — controller-only update
///
/// Authorization resolves an `Auth.Access` from the (caller, token) pair:
///
///   #deny          — no check authorized this read; the call traps
///   #unrestricted  — read every row of every entity
///   #scoped p      — read, but `#owner`-tagged entities yield only rows
///                    owned by principal `p` (see Entity.ownedBy)
///
/// A read is allowed when ANY of these produces a non-`#deny` Access:
///
///   isPublic()                — the whole surface is open (#unrestricted)
///   authorizeUser(caller)     — principal-based policy (e.g. Auth.controllerOnly,
///                               Auth.selfScoped)
///   <token was minted here>   — bearer token from oqlMintToken; its bound
///                               owner (if any) becomes the scope
///   authorizeToken(token)     — author's own token scheme
///
/// The first non-`#deny` in that order wins, and its scope threads into
/// the executor. All three config functions are mandatory; presets live
/// in `Auth.mo`.
///
/// Tokens are bearer credentials carried in query arguments: visible to
/// the node operator and replayable until revoked or expired. Mint with a
/// TTL when handing them to third parties; bind an owner to hand a single
/// user a token that only sees their own rows.
///
/// `execute` is named so because `query` is a reserved keyword in Motoko.

import Map       "mo:core/Map";
import Nat8      "mo:core/Nat8";
import Principal "mo:core/Principal";
import Random    "mo:core/Random";
import Runtime   "mo:core/Runtime";
import Text      "mo:core/Text";
import Time      "mo:core/Time";
import Auth      "Auth";
import Entity    "Entity";
import Executor  "Executor";
import Json      "Json";
import Registry  "Registry";
import Schema    "Schema";

mixin (config : {
  entities       : [Entity.Decl];
  isPublic       : () -> Bool;
  authorizeUser  : Principal -> Auth.Access;
  authorizeToken : Text -> Auth.Access;
}) {

  /// Re-built on every upgrade — entity decls capture closures over actor
  /// fields, which can't be persisted.
  transient let registry : Registry.Registry = Registry.build(config.entities);

  /// A bearer token minted by `oqlMintToken`. `owner = null` is an
  /// unrestricted token (sees everything); `?p` scopes reads to `p`.
  /// `expiresAt = null` never expires.
  type OqlMintedToken = { owner : ?Principal; expiresAt : ?Time.Time };

  /// Minted tokens. `transient` so the mixin contributes no stable field
  /// with an inline initializer — enhanced-migration actors reject those
  /// in the actor body (M0014/M0250). The store resets on upgrade; bearer
  /// tokens are short-lived credentials, so mint fresh ones afterwards.
  /// Expired entries are only pruned in `oqlMintToken` — schema/execute
  /// are query calls whose state changes are discarded.
  transient let oqlMintedTokens : Map.Map<Text, OqlMintedToken> = Map.empty();

  /// The Access a minted token grants right now, or `null` when it is
  /// unknown or expired.
  func oqlMintedTokenAccess(token : Text) : ?Auth.Access =
    switch (oqlMintedTokens.get(token)) {
      case null { null };
      case (?mt) {
        let live = switch (mt.expiresAt) { case null { true }; case (?e) { Time.now() < e } };
        if (not live) { null }
        else { ?(switch (mt.owner) { case null { #unrestricted }; case (?p) { #scoped p } }) };
      };
    };

  /// Resolve the read decision for this caller/token. First non-`#deny`
  /// wins: public, then the principal policy, then a minted token, then
  /// the author's token scheme.
  func oqlAccess(caller : Principal, token : ?Text) : Auth.Access {
    if (config.isPublic()) return #unrestricted;
    switch (config.authorizeUser(caller)) { case (#deny) {}; case (granted) { return granted } };
    switch token {
      case null { #deny };
      case (?t) {
        switch (oqlMintedTokenAccess(t)) {
          case (?a) { a };
          case null { config.authorizeToken(t) };
        };
      };
    };
  };

  /// The query subject an Access scopes to: a concrete principal for
  /// `#scoped`, `null` (unrestricted) otherwise.
  func oqlSubject(a : Auth.Access) : ?Principal =
    switch a { case (#scoped p) { ?p }; case _ { null } };

  public shared query({caller}) func schema(token : ?Text) : async Text {
    switch (oqlAccess(caller, token)) {
      case (#deny) { Runtime.trap("OQL: caller not allowed") };
      case _ { Schema.toJson(Registry.schema(registry)) };
    };
  };

  public shared query({caller}) func execute(qJson : Text, token : ?Text) : async Executor.Result {
    let access = oqlAccess(caller, token);
    switch access { case (#deny) { Runtime.trap("OQL: caller not allowed") }; case _ {} };
    switch (Json.parseQuery(qJson)) {
      case (#err e) { Runtime.trap("OQL: invalid query — " # e) };
      case (#ok q)  { Executor.runScoped(registry, q, oqlSubject(access)) };
    };
  };

  /// Mint a bearer token (32 random bytes, hex). `owner = null` is an
  /// unrestricted token; `?p` scopes every read it makes to `p`'s rows.
  /// `ttlSeconds = null` means no expiry. Controller-only: controllers
  /// pass tokens to whomever they like, and revoke or let them lapse.
  public shared({caller}) func oqlMintToken(owner : ?Principal, ttlSeconds : ?Nat) : async Text {
    if (not caller.isController()) Runtime.trap("OQL: only controllers mint tokens");

    // Opportunistic prune — the only update context that touches the store
    // besides revoke, so expired entries can't accumulate unboundedly.
    let now = Time.now();
    for ((t, mt) in oqlMintedTokens.entries().toArray().values()) {
      switch (mt.expiresAt) { case (?e) { if (e <= now) ignore oqlMintedTokens.delete(t) }; case null {} };
    };

    let token = oqlHex(await Random.blob());
    // TTL anchored after the await — `now` above predates the raw_rand
    // round-trip and would silently shorten the token's lifetime.
    let expiresAt = switch ttlSeconds {
      case null  { null };
      case (?s)  { ?(Time.now() + s * 1_000_000_000) };
    };
    oqlMintedTokens.add(token, { owner; expiresAt });
    token
  };

  /// Returns true when the token existed (and is now gone).
  public shared({caller}) func oqlRevokeToken(token : Text) : async Bool {
    if (not caller.isController()) Runtime.trap("OQL: only controllers revoke tokens");
    oqlMintedTokens.delete(token)
  };

  transient let oqlHexDigits = "0123456789abcdef".chars().toArray();

  func oqlHex(b : Blob) : Text {
    var out = "";
    for (byte in b.toArray().values()) {
      out := out # oqlHexDigits[Nat8.toNat(byte / 16)].toText()
                 # oqlHexDigits[Nat8.toNat(byte % 16)].toText();
    };
    out
  };

};
