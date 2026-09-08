# caffeineai-lints

Shared [lintoko](https://github.com/ZenVoich/lintoko) rules for Caffeine-generated Motoko projects.

## Rules

### `migration-self-contained`

Migration files must not import local modules (relative paths). If an imported
module changes after a migration is frozen, the migration chain breaks and
cannot be repaired by agents. Inline types and values directly in the migration
file instead.

Applies to: `**/src/backend/migrations/*.mo`

### `no-base-import`

`mo:base` is deprecated and kept only for backwards compatibility — all new code
should import from `mo:core` instead. Warns on any `mo:base/...` import so
projects get a visible nudge while migrating away from it.

Severity: warning (reported but never fails `mops check` / `mops lint`).

Applies to: all `.mo` files.
