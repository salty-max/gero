# Development reference

Long-form companion to [`CLAUDE.md`](../CLAUDE.md). CLAUDE.md
holds the rules that govern every PR (specs-first reading,
workflow contract, self-review loop, code rules, build gates).
This file holds the structural references Claude reads only when
needed — source layout, the full lint rule list, the
branch/commit/changeset conventions, the release flow, and the
tech-stack one-liner.

---

## Source layout

```
src/
├── gero.zig               # Public barrel
├── vm/                    # Bytecode interpreter
├── asm/                   # Assembler (consumes knit)
├── disasm/                # Disassembler
├── lang/                  # Gero language compiler (consumes knit)
└── common/                # Shared types: Value, Bytecode, Span

tests/
├── util.zig               # Shared test helpers
├── gero.test.zig          # Public-surface smoke tests
└── <mod>/<file>.test.zig  # Mirrors src/<mod>/<file>.zig

apps/         # CLIs
docs/         # ISA spec + lang spec
editors/      # Tree-sitter grammar + VS Code ext (submodules)
tools/        # Single-binary dev utilities (lint, etc.)
scripts/      # Bash helpers for build.zig + lefthook
.changeset/   # *.md changeset files
.github/      # Workflows + templates
```

**Mirror rule:** every `src/<mod>/<file>.zig` requires a matching
`tests/<mod>/<file>.test.zig` — lint-enforced. Exempt:
`src/gero.zig` and any top-level module barrel (e.g. `src/lang.zig`).

`internal.zig` colocated with a module dir is the convention for
private helpers — exempt from the mirror rule, must not be
re-exported through `src/gero.zig`, exercised through its
consuming modules' tests.

**Imports:** single-level relative only. `../foo.zig` or `./foo.zig`
— anything deeper (`../../...`) is rejected by the lint binary.
Public consumers (and tests) import only `gero`:

```zig
const gero = @import("gero");
```

Tests can also import `../util.zig` (one level) for shared helpers.

---

## Strict-mode lint (`gero-lint`)

Single Zig binary at `tools/lint/main.zig`, built as
`zig-out/bin/gero-lint`, runs in ~2–3s. Fails on any of these in
`src/`:

- `anyerror`, `*anyopaque` / `*const anyopaque`
- `@as(` / `@ptrCast(` / `@alignCast(` / `@bitCast(` without
  `// @as:` / `// safety:` justification directly above
- `unreachable` / `@compileError("TODO")` without a justifying
  comment
- `std.debug.print` outside test code
- `catch unreachable` without `// allow-strict: <invariant>`
- `catch |x| return x` — use `try` instead
- `std.heap.page_allocator` direct use — accept allocators from
  callers
- `usingnamespace`
- `//!` file-level doc anywhere except the top barrel
- Issue numbers / version markers in any comment
- Mirror-layout violations
- Multi-level relative imports (`../../`)
- Naming: `pub fn Foo(...) type` must be PascalCase;
  `pub fn foo(...) <other>` must be camelCase
- Public declarations without `///` doc comments

Allowlist a violation with `// allow-strict: <reason>` directly
above the line. Reviewer-gated — bring a real reason.

`pub const` naming is convention-only (not enforced): PascalCase
for types (`pub const Foo = struct {...}`), snake_case for values
(`pub const max_count = 42`).

---

## Branches + commits + changesets

**Branches:**

- `feat/<short>` — new module, new public API
- `fix/<short>` — bug fix
- `perf/<short>` — measurable performance improvement
- `chore/<short>` — tooling, deps, CI, build
- `docs/<short>` — docs-only change
- `refactor/<short>` — internal restructure, no behavior change

Branch from `main`. One issue → one branch → one PR end-to-end
(no chunking — see CLAUDE.md "The contract").

**Commits:** Conventional Commits enforced by **convco** with a
strict scope-enum from `.versionrc`.

- No scope-less commits (`feat: add x` → rejected)
- Multi-concern changes split into multiple commits in the PR
- `fixup!` for review feedback, then `--autosquash`
- Tooling-only `perf` → use `chore(tooling)` (changeset gate
  auto-skips). Library API perf wins stay `perf(<scope>)`.

**Allowed scopes:**

```
vm                  → src/vm/*
asm                 → src/asm/*
disasm              → src/disasm/*
lang                → src/lang/*
common              → src/common/*
tooling             → build.zig, lefthook, convco, tools/*, scripts/*
ci                  → .github/workflows/*
docs                → in-source doc comments, README, doc files
meta                → top-level repo files (CLAUDE.md, LICENSE, root configs)
<area>/<sub>        → e.g. lang/codegen, vm/handlers, asm/parser
apps/<name>         → apps/<name>/
editors/<name>      → editors/<name>/
```

**Changesets** — every PR with a user-visible change drops
`.changeset/<short>.md`. CHANGELOG + version bump derive from
accumulated changesets at release time.

- **Add one** for `feat`, `fix`, library-level `perf`, breaking
  refactor.
- **Skip** for `chore`, `docs`, `test`, internal-only `refactor`,
  `ci`, `build`, `style`. The `changeset-check` workflow
  auto-skips these PR titles.

`zig build changeset` scaffolds one interactively.

---

## Releases (manual)

Releases are cut manually. Multiple merged PRs accumulate
changesets on `main`; the maintainer cuts a release when several
are worth a coherent semver bump. Pushing to `main` runs CI but
**never** publishes — only pushing a `vX.Y.Z` tag triggers
`release.yml`.

```bash
git checkout main && git pull
zig build version           # consume changesets, bump version, prepend CHANGELOG
git diff                    # review the generated CHANGELOG, edit by hand if needed
git add . && git commit -m "chore(meta): release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

---

## Tech stack (one-liner reference)

Zig 0.16.0 minimum (pinned in `build.zig.zon`), zero runtime deps,
`build.zig` is the task runner (no Makefile, no shell wrapper —
`zig build --help` lists every step), `zig fmt` via
`zig build fmt`/`fmt-check`, lint via `zig build lint`, git hooks
via [lefthook](https://github.com/evilmartians/lefthook),
commits via [convco](https://github.com/convco/convco), changesets
as manual `.changeset/*.md` files.
