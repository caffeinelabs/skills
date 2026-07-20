# AGENTS.md

Monorepo of agent-readable skill files (`skills/`) and the reusable Motoko/TypeScript packages (`packages/`) they document, for building on the Caffeine AI / Internet Computer platform.

## Layout

- `skills/<name>/SKILL.md` — self-contained markdown with YAML frontmatter, consumed by coding agents. `extension-*` document a `packages/` component; `connector-*` document external-service integrations. Some skills add a `migration/` folder.
- `packages/<name>/backend/` — Motoko package (`mops.toml`). Published to the mops registry as `caffeineai-*`.
- `packages/<name>/frontend/` — TypeScript package (`package.json`). Published to GitHub Packages as `@caffeineai/*`.
- `packages/<name>/backend/rules/` — lintoko rule definitions (`.toml`) shipped with the package.
- `packages/caffeine-lints/` — shared lintoko rules used across backend packages.

There is no root build system, workspace manifest, or CI workflow; each package builds independently.

## Frontend packages (run inside a `packages/*/frontend/` dir)

Available npm scripts (verify per package; not all define every one):

- `npm run build` — compile with `tsc`.
- `npm run type-check` — `tsc --noEmit`.
- `npm run test` — run `src/**/*.test.ts` via the Node test runner (present only where tests exist).
- `npm run biome:check` — lint + format check. Runs with `--error-on-warnings`, so any warning fails.
- `npm run biome:check:fix` — apply Biome autofixes.
- `npm run clean` — remove `dist`.

## Backend packages (run inside a `packages/*/backend/` dir)

- Use [mops](https://mops.one) for dependencies and tooling.
- Each `mops.toml` pins exact tool versions in `[toolchain]` (e.g. `moc`, `lintoko`, `pocket-ic`). Use those versions.
- Packages with a `[dev-dependencies] test` entry and a `test/` folder of `*.test.mo` files are exercised with `mops test`.
- Extra compiler flags live under `[moc] args` in `mops.toml`; respect them when building.

## Conventions & gotchas

- Committed `dist/` directories and `node_modules/` are tracked in git. `dist/` is generated from `src/` — never hand-edit it; change `src/` and rebuild.
- `mops.lock` files are committed for some backend packages; update them via mops rather than by hand.
- A skill's frontmatter `compatibility` versions must match the actual published package versions it documents.
- Formatting/linting on frontend code is Biome, enforced with zero tolerance for warnings.
- License is Apache-2.0; keep the `license` field in new `package.json`/`mops.toml` consistent.
