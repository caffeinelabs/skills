/// Pre-built policies for `Expose`'s auth functions, plus the `Access`
/// decision they return. Each config field accepts any function of the
/// right shape; these are just the common cases spelled once.
///
/// `Access` carries both the allow/deny decision AND the read scope:
///
///   #deny          — the check does not authorize this caller/token
///   #unrestricted  — authorized to read every row of every entity
///   #scoped p      — authorized, but `#owner`-scoped entities yield
///                    only rows owned by principal `p`
///
/// A read is allowed when any configured check returns a non-`#deny`
/// `Access`. The resolved scope threads into the executor (see Expose).

import Principal "mo:core/Principal";

module {

  public type Access = {
    #deny;
    #unrestricted;
    #scoped : Principal;
  };

  /// `authorizeUser` preset: controllers read everything, nobody else
  /// passes on the principal path. Sensible default for production
  /// canisters exposing private state.
  public func controllerOnly(p : Principal) : Access =
    if (p.isController()) #unrestricted else #deny;

  /// `authorizeUser` preset: every non-anonymous caller is authorized but
  /// scoped to its own rows (rows of `#owner`-tagged entities whose owner
  /// equals the caller). The per-user default for end-user-facing apps.
  public func selfScoped(p : Principal) : Access =
    if (p.isAnonymous()) #deny else #scoped p;

  /// `authorizeUser` preset: no principal is special — combine with
  /// `isPublic` or token policies.
  public func noUsers(_ : Principal) : Access = #deny;

  /// `authorizeToken` preset: no author-side token scheme. Tokens minted
  /// via `oqlMintToken` keep working — the mixin checks its own store
  /// before this function.
  public func noExternalTokens(_ : Text) : Access = #deny;

};
