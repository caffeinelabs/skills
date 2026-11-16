# AGENTS.md

Monorepo of agent-readable skill files and the reusable packages they document for building on the Caffeine AI platform (Motoko backends on ICP + TypeScript/React frontends).

## Layout

- `skills/` — the primary deliverable. One directory per skill, each a self-contained `SKILL.md` with YAML frontmatter (`name`, `description`, `version`, `compatibility`). `extension-*` document a package; `connector-*`, `migrating-*`, and `writing-*`/`reviewing-*` are guides. Some skills carry helper `scripts/`.
- `packages/` — reusable code published from the skills. Each package may have `backend/` (Motoko, `mops.toml`, published to mops as `caffeineai-*`) and/or `frontend/` (TypeScript, `package.json`, published as `@caffeineai/*`).

## Build / test / lint

There is **no root build file, workspace config, or CI workflow**. There is no root `package.json`. Every package is built on its own — `cd` into the specific `packages/<name>/frontend` or `.../backend` first.

Frontend packages (TypeScript) expose these npm scripts (verify in the package's own `package.json`, not all packages define every one):

- `npm run build` — `tsc`
- `npm run type-check` — `tsc --noEmit`
- `npm run biome:check` — lint + format check; **fails on warnings**
- `npm run biome:check:fix` — apply Biome fixes
- `npm test` — present only on some packages (e.g. `core-infrastructure`), runs the Node test runner

Backend packages (Motoko) are mops packages; build/test them with the mops CLI from inside `packages/<name>/backend` per that package's `mops.toml`.

## Conventions and gotchas

- Formatting/linting is Biome; code is tab-indented. `biome:check` runs with `--error-on-warnings`, so warnings break the check.
- `dist/` in frontend packages is the compiled `tsc` output — generated, never hand-edit it.
- Frontend packages depend on each other via the `workspace:*` protocol, so resolve local packages through the workspace rather than installing from the registry.
- The Motoko toolchain is pinned **per package** in each `mops.toml` `[toolchain]` section (`moc` versions vary across packages, e.g. 1.7.0, 1.14.0, 1.16.0); use the version declared in the package you are editing.
- A skill's `compatibility` frontmatter pins the exact package versions it documents — keep it in sync when changing a package's public API.
- License is Apache-2.0.
