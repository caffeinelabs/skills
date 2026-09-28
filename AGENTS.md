# AGENTS.md

Monorepo of agent-readable skill files and their supporting Motoko/TypeScript packages for building on the Caffeine AI (Internet Computer / ICP) platform.

## Layout

- `skills/` — one directory per skill, each containing a self-contained `SKILL.md` with YAML frontmatter. Directory prefixes: `extension-*` document reusable components, `connector-*` document third-party integrations, and the remaining `*-motoko*` / `mops-cli` skills document Motoko workflows. Some skills add `references/`, `examples.md`, or `api-reference.md` alongside `SKILL.md`.
- `packages/` — implementation of the extensions referenced by skills. Each package has a `backend/` (Motoko, `mops.toml`) and/or `frontend/` (TypeScript, `package.json`); most packages are backend-only.

## Backend packages (Motoko / mops)

- Each `packages/*/backend/` is a mops package published to the mops registry as `caffeineai-*`.
- Tool versions are pinned per package in `mops.toml` under `[toolchain]` and `[requirements]` (e.g. `moc`, `pocket-ic`, `lintoko`); versions differ between packages — use the value in the package you are editing.
- Packages with tests keep them in `backend/test/*.test.mo` using the `mo:test` dev dependency declared in `mops.toml`.
- `mops.lock` is generated; do not hand-edit it.
- Several backends contain a `rules/` directory of lintoko rule files (`*.toml`); `packages/caffeine-lints` holds the shared lintoko rules (`caffeineai-lints`).

## Frontend packages (TypeScript / npm)

Published to GitHub Packages as `@caffeineai/*`. Scripts are defined per package in `package.json`; not every package defines every script. Observed scripts:

- `build` — `tsc`
- `type-check` — `tsc --noEmit`
- `biome:check` — `biome check --error-on-warnings .` (formatting/lint gate; fails on warnings)
- `biome:check:fix` — `biome check --write --error-on-warnings .`
- `test` — only `packages/object-storage/frontend` defines this (`node --import tsx --test src/**/*.test.ts`)

Frontend `tsconfig.json` files extend a shared `tsconfig.base.json` and `biome` config that are not part of this checkout; the toolchain expects them to be present in the wider workspace.

## Conventions

- `dist/`, `node_modules/`, and `*.tgz` artifacts under packages are build/publish outputs; do not hand-edit them.
- Skill frontmatter `version` and `compatibility` pin the exact mops/npm package versions each skill documents; keep them consistent with the corresponding package's version when changing either.
- License is Apache-2.0.
