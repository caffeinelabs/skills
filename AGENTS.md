# AGENTS.md

Agent-readable skill files and their backing packages for building on Caffeine AI.

## Layout

- `skills/` — one directory per skill, each a self-contained `SKILL.md` with YAML
  frontmatter (`name`, `description`, `version`, `compatibility`). Some skill
  directories also carry `migration/`, `references/`, or `scripts/` subdirectories.
- `packages/<name>/backend/` — Motoko packages (`mops.toml`), published to the mops
  registry as `caffeineai-*`.
- `packages/<name>/frontend/` — TypeScript packages (`package.json`), published as
  `@caffeineai/*`.
- `packages/<name>/backend/rules/` — lintoko rule definitions (`.toml`).

## Backend (Motoko / mops)

Each backend package pins its toolchain in `mops.toml` under `[toolchain]` and/or
`[requirements]` — honor the `moc` and `pocket-ic` versions declared per package;
they are not uniform across packages. Dependencies and dev-dependencies are listed
in the same `mops.toml`.

Lint rules live in `packages/*/backend/rules/*.toml` and are enforced by lintoko
(version pinned in `packages/caffeine-lints/backend/mops.toml`). Notably, `mo:base`
imports are flagged — use the `mo:core` equivalents instead.

## Frontend (TypeScript)

Frontend packages are a pnpm workspace (cross-package deps use `workspace:*`).
Verified `package.json` scripts (availability varies per package — check the
package's own `package.json`):

- `build` → `tsc`
- `type-check` → `tsc --noEmit`
- `biome:check` → `biome check --error-on-warnings .`
- `biome:check:fix` → `biome check --write --error-on-warnings .`
- `test` → `node --import tsx --test src/**/*.test.ts` (where present)

Biome is the formatter/linter and runs with `--error-on-warnings`, so warnings fail.

## Conventions

- There is no repository-root build, test, or CI configuration; operate within an
  individual package or skill directory.
- `packages/*/frontend/dist/` is build output (`tsc`) — never hand-edit it.
- Skill `compatibility` versions and package `version` fields are kept in sync with
  the published packages; keep them consistent when editing.

## License

Apache-2.0.
