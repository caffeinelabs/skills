# AGENTS.md

Collection of agent-readable skill files and their reusable packages for building on the Caffeine AI platform (Internet Computer / Motoko + React).

## Layout

- `skills/` — one directory per skill, each a self-contained `SKILL.md` with YAML frontmatter. `extension-*` document platform extensions; `connector-*` document third-party connectors; the remaining directories (e.g. `writing-motoko`, `reviewing-motoko`, `migrating-to-moc-2`) are Motoko authoring/migration guides. Edit skill behavior here.
- `packages/` — reusable source backing some extensions. Each package has a `backend/` (Motoko, published to the mops registry as `caffeineai-*`) and/or a `frontend/` (TypeScript, published as `@caffeineai/*`).

## Backend packages (`packages/*/backend`)

Motoko packages managed with [mops](https://mops.one). Each has its own `mops.toml`.

- The `moc` (and sometimes `lintoko`) version is pinned per package in the `[toolchain]` section of its `mops.toml`. Use the version declared there; it is not uniform across packages.
- `rules/*.toml` are lintoko lint rules. `caffeineai-lints` holds shared rules (e.g. `no-base-import`: `mo:base` is deprecated, use the `mo:core` equivalent).
- `mops.lock` is generated; do not hand-edit.

## Frontend packages (`packages/*/frontend`)

Standalone npm packages. Verified scripts (run inside the package directory):

- `npm run build` — `tsc`
- `npm run type-check` — `tsc --noEmit`
- `npm run biome:check` — Biome lint/format check (fails on warnings)
- `npm run biome:check:fix` — apply Biome fixes
- `npm run clean` — remove `dist`
- `npm test` — present only in `core-infrastructure` and `object-storage`; runs `node --import tsx --test src/**/*.test.ts`

Note: each `tsconfig.json` extends `../../../tsconfig.base.json` and `biome:check` expects a Biome config; neither config is checked in at the repo root, so these scripts assume additional setup not present in a bare checkout.

## Generated artifacts — do not hand-edit

- `packages/*/frontend/dist/` — `tsc` build output.
- `packages/*/frontend/node_modules/` — installed dependencies.
- `packages/**/*.tgz` — packed package tarballs.

## Conventions

- Backend module imports use `mo:caffeineai-*`; frontend imports use `@caffeineai/*`.
- Frontend packages reference workspace siblings via `"workspace:*"`.
- Every package and skill is Apache-2.0 licensed.
