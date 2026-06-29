# AGENTS.md

Agent-readable skill files and the reusable packages they document, for building
on the Caffeine AI platform (Motoko backend + TypeScript/React frontend on ICP).

## Layout

- `skills/extension-*/SKILL.md` — self-contained skill files with YAML
  frontmatter; the canonical, human/agent-facing documentation.
- `packages/<name>/backend/` — Motoko packages published to mops as
  `caffeineai-*` (`mops.toml`, `src/`, `rules/`).
- `packages/<name>/frontend/` — TypeScript/React packages published as
  `@caffeineai/*` (`package.json`, `src/`, `tsconfig.json`).
- `packages/caffeine-lints/` — shared lint rules consumed by other packages.

A package may have only `backend/`, only `frontend/`, or both.

## Frontend packages

Each frontend package defines these `package.json` scripts (run from inside the
package's `frontend/` directory):

- `npm run build` — compile with `tsc`.
- `npm run type-check` — `tsc --noEmit`.
- `npm run biome:check` — lint/format check (fails on warnings).
- `npm run biome:check:fix` — apply Biome fixes/formatting.
- `npm run clean` — remove `dist`.

There is no root workspace or root `package.json`; install and run scripts
per package.

Each `frontend/tsconfig.json` extends `../../../tsconfig.base.json` (a repo-root
base config). `dist/` is build output — never hand-edit it.

## Backend packages

Backend packages are Motoko, managed with mops (`mops.toml`, `mops.lock`).
`mops.toml` pins the Motoko toolchain (`[toolchain] moc`) and dependency
versions; respect these pins.

`packages/<name>/backend/rules/*.toml` are tree-sitter lint rules (each a
`name`, `description`, and `query`). They enforce that consuming apps include
required mixins and do not redeclare reserved declarations.

## Conventions

- Formatting/linting on the frontend is Biome, configured to **error on
  warnings** — code must be warning-clean to pass `biome:check`.
- Indentation in config and source files is tabs.
- Both backend and frontend are licensed Apache-2.0.
- A `SKILL.md` frontmatter `compatibility` block lists the exact mops/npm
  package versions it documents; keep skills and the packages they document in
  sync.
