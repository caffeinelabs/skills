# AGENTS.md

A monorepo of agent-readable skill files plus the Motoko (backend) and TypeScript (frontend) packages they document, for building on the Internet Computer.

## Layout

- `skills/` — self-contained `SKILL.md` files (with YAML frontmatter). `extension-*` document a package; `connector-*` and the remaining directories (e.g. `writing-motoko`, `reviewing-motoko`, `mops-cli`) are standalone guidance.
- `packages/<name>/backend/` — Motoko package, published to the mops registry as `caffeineai-*`. Config in `mops.toml`.
- `packages/<name>/frontend/` — TypeScript package, published as `@caffeineai/*`. Config in `package.json`.

Each package is independent; there is no root build file or workspace manifest. Run commands from inside the individual package directory.

## Frontend packages (`packages/*/frontend/`)

Uses [Biome](https://biomejs.dev) and TypeScript. Scripts (see each `package.json` — not every package defines all):

- Build: `npm run build` (`tsc`)
- Type-check: `npm run type-check` (`tsc --noEmit`)
- Lint/format: `npm run biome:check` (fails on warnings); `npm run biome:check:fix` to apply fixes
- Test (where present, e.g. `object-storage`): `npm run test`

## Backend packages (`packages/*/backend/`)

Motoko, managed with [mops](https://mops.one). Each `mops.toml` pins its own `moc` (and, where used, `pocket-ic`) version under `[toolchain]` — install those pinned tools rather than a global default. `mops build` and `mops test` run against the package. Tests live in `test/` as `*.test.mo` files.

## Conventions

- `dist/` (frontend) is generated build output; never hand-edit it.
- `packages/*/frontend/node_modules/` may be checked out but is not source; do not edit vendored packages.
- Skill frontmatter `compatibility` versions must match the actual published `mops.toml` / `package.json` versions the skill documents.
- License is Apache-2.0.
