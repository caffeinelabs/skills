# AGENTS.md

Monorepo of agent-readable skill files and the reusable Motoko/TypeScript packages they document, for building apps on the Caffeine AI platform (Internet Computer / ICP).

## Repository layout

- `skills/` — one directory per skill, each a self-contained `SKILL.md` with YAML frontmatter. `extension-*` document platform components; `connector-*` document third-party integrations; the rest (e.g. `writing-motoko`, `reviewing-motoko`, `mops-cli`) are topic guides. Some skills carry a `migration/` subdir and helper `scripts/`.
- `packages/` — the published implementations the skills describe. Each package has a `backend/` (Motoko, `mops.toml`) and/or `frontend/` (TypeScript, `package.json`).

Backend packages publish to the mops registry as `caffeineai-*`; frontend packages publish to GitHub Packages as `@caffeineai/*`.

## Build, test, lint, format

There is no root build system; run commands inside the individual package directory.

Frontend packages (`packages/*/frontend/`, npm scripts):

- Build: `npm run build` (runs `tsc`)
- Type-check: `npm run type-check` (`tsc --noEmit`)
- Lint + format check: `npm run biome:check` (fails on warnings)
- Auto-fix lint/format: `npm run biome:check:fix`
- Clean: `npm run clean`
- Test (only `core-infrastructure` and `object-storage` define it): `npm run test`

Backend packages (`packages/*/backend/`) are mops packages. Build/test with the `mops` CLI; files matching `test/*.test.mo` are the test suites.

## Conventions and gotchas

- Frontend inter-package dependencies use `workspace:*`, so packages must be installed/built from a workspace-aware tool, not a bare per-directory `npm install`.
- Pinned toolchain versions live in each `mops.toml` `[toolchain]` (e.g. `moc`, `lintoko`); do not assume a global version.
- `packages/*/backend/rules/*.toml` are lintoko rules (not config you edit casually): `no-base-import` flags `mo:base` imports — use the `mo:core` equivalent (e.g. `mo:core/Array`) instead.
- `dist/` is build output (`tsc`); never hand-edit it. `node_modules/` is vendored in some package trees; never edit it.
- A skill's documented package versions are declared in its `SKILL.md` frontmatter `compatibility.mops` / `compatibility.npm`; keep them consistent with the corresponding `mops.toml` / `package.json`.
- License is Apache-2.0.
