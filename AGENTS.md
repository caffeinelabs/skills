# AGENTS.md

Monorepo of agent-readable skill files and their supporting Motoko/TypeScript packages for building on Caffeine AI (Internet Computer canisters).

## Layout

- `skills/` — one directory per skill, each a self-contained `SKILL.md` with YAML frontmatter. Prefixes: `extension-*` (documents a package pair), `connector-*` (external-service recipes, marked experimental in their frontmatter), plus standalone guides (`writing-motoko`, `reviewing-motoko`, `migrating-motoko-actors`, `troubleshooting-motoko-migrations`, `mops-cli`).
- `packages/<name>/backend/` — Motoko package published to the mops registry as `caffeineai-*` (has `mops.toml`).
- `packages/<name>/frontend/` — TypeScript package published as `@caffeineai/*` (has `package.json`).
- `packages/<name>/backend/rules/` — [lintoko](https://github.com/ZenVoich/lintoko) lint rules (tree-sitter queries in `.toml`) enforced on generated Motoko projects, not on this repo's own source.

There is no root-level build system, workspace manifest, CI workflow, or `.gitignore`. Each package is built and versioned independently.

## Frontend packages (TypeScript)

Verified scripts in each `packages/*/frontend/package.json`:

- `npm run build` — `tsc`
- `npm run type-check` — `tsc --noEmit`
- `npm run biome:check` — `biome check --error-on-warnings .` (lint + format check; fails on warnings)
- `npm run biome:check:fix` — `biome check --write --error-on-warnings .`
- `npm run clean` — `rimraf dist`

`biome` and `tsc` are expected on `PATH` (not pinned as dependencies). React and `@types/*` versions are pinned per package; do not upgrade them casually.

## Backend packages (Motoko)

Each `packages/*/backend/mops.toml` pins the Motoko compiler under `[toolchain]` (e.g. `moc = "1.7.0"`) and dependency versions; `mops.lock` is committed where present. Build/test these with the mops CLI (see `skills/mops-cli/SKILL.md`).

## Conventions and gotchas

- Compiled `dist/` output and `node_modules/` are checked into git. Never hand-edit files under `dist/`; regenerate with `npm run build`.
- Frontend inter-package deps use `workspace:*`; resolve them from within this monorepo.
- `SKILL.md` frontmatter drives package resolution: `name`, `description`, `version`, and `compatibility.mops` / `compatibility.npm` version ranges. Keep the documented ranges in sync with the actual package versions.
- Every publishable package is `Apache-2.0`.
