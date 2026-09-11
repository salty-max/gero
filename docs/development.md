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

Branch from `main`. One PR carries one or more issues end-to-end,
one commit each; a single issue is never chunked across PRs — see
CLAUDE.md "The contract".

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

## The wasm lane

Every fenced code block in the docs is compiled: `check-doc-asm.sh`
assembles the ```asm ones and `check-doc-gr.sh` parses the ```gero
ones, both driven from `zig build verify`. They take a document list
that globs `docs/book/*.md` and `docs/machine/*.md`, so a new chapter
is covered without touching `build.zig` — a teaching example that
quietly stopped working is worse than none, because a beginner cannot
tell whether the book or their typing is wrong.

`scripts/check-diag-registry.sh` (also on `verify`) diffs every
`E_*` / `W_*` code three ways: meaning table, registry table, emit
site in `src/`. A documented code with no emission site is a promise
nothing keeps; an emitted code with no row is a diagnostic a reader
cannot look up. The same script checks that the Vec / str operations
tables in `gero-lang.md` name only methods the typechecker implements.

`zig build test-wasi` runs the whole suite under `wasmtime` for
wasm32-wasi. It needs `-fwasmtime` and `wasmtime` on PATH, so it is
not part of the local `ci` aggregate — GitHub Actions installs the
runtime and gates it there.

`zig build wasm` builds `gero.wasm` (`docs/gero-lab.md` §2) and emits
the sample corpus alongside it. `zig build test-wasm-examples` runs
every example through that module and diffs against the same
`.expected` files the native gates use.

That gate needs **node**. The Zig toolchain cannot execute wasm on its
own, and a JS host is what the module is built for — so the alternative
to a JS runner is proving only that `wasm32` compiles, which the
cross-target matrix already does. Everything else gero tests at runtime
runs natively; this is the one place that runs somewhere else.

It is wired into `verify` and `ci`, and runs on pull requests.

---

## Documentation gates

Two gates compile the examples in the docs, because a spec example is
what someone learning the language copies — one that no longer works
teaches wrong syntax, silently.

| Gate | Checks | Marker for a block that cannot stand alone |
|---|---|---|
| `zig build check-doc-asm` | every ` ```asm ` block in `docs/asm.md` assembles | first line `; fragment: <why>` |
| `zig build check-doc-gr` | every ` ```gero ` block in `docs/gero-lang.md` parses | first line `-- fragment: <why>` |

Both are wired into `verify`.

**Only tagged blocks are checked.** A bare ` ``` ` fence is prose — a
keyword list, a memory map, an API signature table — and is skipped.
Tag a block ` ```gero ` when it is gero, which is also what gives it
syntax highlighting.

**The `.gr` gate checks syntax, not types.** Most blocks are fragments
that reference symbols the surrounding prose defines, so type errors
are expected and ignored. A syntax error never is.

Reach for `-- fragment:` only when a block genuinely cannot parse:
an elided body (`...`), a form the section is documenting *as* an
error, or a desugaring written in terms the parser never sees. If a
block fails because the language changed under it, fix the block.

The `.gr` gate found three of these on the day it was added — `def` as
a struct field, `use` and `step` as function names, all reserved since
§2.6 — plus a range example using integer suffixes and a `match` using
a leading-dot variant shorthand, neither of which the language has.

---

## Releases (manual)

Releases are cut manually. Multiple merged PRs accumulate
changesets on `main`; the maintainer cuts a release when several
are worth a coherent semver bump. Pushing to `main` runs CI but
**never** publishes — only pushing a `vX.Y.Z` tag triggers
`release.yml`.

Below 1.0 the bump levels shift one place right: a `major` changeset
moves the minor, `minor` and `patch` move the patch. `zig build
version` therefore cannot produce `1.0.0` — declaring the API stable
is a decision, not the arithmetic consequence of a changeset that said
`major`. See [`.changeset/README.md`](../.changeset/README.md).

```bash
git checkout main && git pull
zig build version           # consume changesets, bump version, prepend CHANGELOG
git diff                    # review the generated CHANGELOG, edit by hand if needed
git add . && git commit -m "chore(meta): release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

---

## Cache maintenance

Zig content-hashes every build output into its own `.zig-cache/o/<hash>`
dir and **never reclaims old ones** — there is no built-in GC. A
cross-target / multi-mode workflow (`zig build ci` runs 4 release modes
× 5 targets) mints fresh outputs every commit, so the cache grows without
bound. Left alone it reaches tens or hundreds of GB.

```bash
zig build clean         # full wipe of zig-out + .zig-cache → next build is cold
zig build clean-cache   # prune only .zig-cache/o dirs older than MAX_AGE_DAYS
```

`clean-cache` (`scripts/clean-cache.sh`) is the routine maintenance one:
it drops stale output dirs while leaving the warm working set intact, so
the next build is *not* cold. Active builds keep a fresh mtime and
survive; only artifacts from commits you haven't touched in
`MAX_AGE_DAYS` (default 3) go. A pruned output is just a cache miss —
Zig rebuilds it on demand. Override with `MAX_AGE_DAYS=N zig build
clean-cache`, or wire a scheduled job to the script for hands-off
upkeep.

---

## Tech stack (one-liner reference)

Zig 0.16.0 minimum (pinned in `build.zig.zon`), zero runtime deps,
`build.zig` is the task runner (no Makefile, no shell wrapper —
`zig build --help` lists every step), `zig fmt` via
`zig build fmt`/`fmt-check`, lint via `zig build lint`, git hooks
via [lefthook](https://github.com/evilmartians/lefthook),
commits via [convco](https://github.com/convco/convco), changesets
as manual `.changeset/*.md` files.
