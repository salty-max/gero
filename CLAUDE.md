# Gero — Claude Guidelines

## Project Overview

Gero is a hobby ecosystem in Zig: a 16-bit virtual machine, an
assembler and disassembler for its bytecode, and a Lua-style language
that compiles to that bytecode. The fantasy-console (gtx-16) and web
playground (gero-lab) are out of scope for this repo — they live or
will live elsewhere and consume gero as a library.

The library is **gero**. Package name in `build.zig.zon` is `.gero`,
module is `@import("gero")`, public barrel is `src/gero.zig`.

What gero **is**:

- A VM kernel + asm/disasm + language compiler, all pure Zig
- Designed for native + `wasm32-wasi` (web shells consume the WASM)
- Built on top of [knit](https://github.com/salty-max/knit) for the
  parser-combinator layer (asm + lang use it)

What gero **is not**:

- A general-purpose VM — the ISA is custom and bounded to 16-bit
- A self-hosting compiler — the lang compiler is in Zig
- A graphics / IO runtime — that lives in the gtx-16 shell

## Workflow Contract

**Issue → branch → PR → wait for merge signal → next issue.**
Never batch issues into a single PR. Never start the next issue
before the current one is explicitly merged. The maintainer
controls cadence; the implementer waits for the go-ahead.

When the issue body lists acceptance criteria, treat them as the
definition of done — not green CI. Re-read them before declaring
the work finished (see [Self-Review](#self-review-before-declaring-done)).

## Tech Stack

- **Zig 0.16.0** minimum (pinned in `build.zig.zon`)
- **Zero runtime deps** — pure Zig, no C deps, no FFI (the language
  layer bridges to whatever the host exposes; the core has no I/O)
- **Build / test / lint / release tooling**: `build.zig` is the task
  runner. Every dev command is `zig build <step>`. No Makefile, no
  shell wrapper. Run `zig build --help` to list every step.
- **Format**: `zig fmt` (driven via `zig build fmt` / `fmt-check`)
- **Lint**: single Zig binary at `tools/lint/main.zig`, built as
  `zig-out/bin/gero-lint`, runs every rule against the in-memory
  source tree in ~2-3s
- **Git hooks**: [lefthook](https://github.com/evilmartians/lefthook)
- **Conventional commits**: [convco](https://github.com/convco/convco)
  — scope-enum enforced via `.versionrc`
- **Changesets**: manual `.changeset/*.md` format with shell scripts

## Source Layout

```
src/
├── gero.zig               # Public barrel
├── vm/                    # Bytecode interpreter (registers, memory, dispatch)
├── asm/                   # Assembler (text → bytecode); consumes knit
├── disasm/                # Disassembler (bytecode → text)
├── lang/                  # Gero language compiler (text → bytecode); consumes knit
└── common/                # Shared types: Value, Bytecode, Span

tests/
├── util.zig               # Shared test helpers
├── gero.test.zig          # Public-surface smoke tests
├── vm/<file>.test.zig     # Mirrors src/vm/<file>.zig
├── asm/<file>.test.zig    # Mirrors src/asm/<file>.zig
└── …

apps/                      # CLIs land here when needed
docs/                      # ISA spec + lang spec live here
editors/                   # Editor tooling — tree-sitter grammar + VS Code ext (submodules)
tools/                     # Single-binary dev utilities (lint, etc.)
scripts/                   # Bash helpers for build.zig + lefthook (slim — most logic in tools/)
.changeset/                # *.md changeset files
.github/                   # workflows + templates
.gitmodules                # Submodule pinning
```

The `src/gero.zig` barrel and any `src/<module>.zig` (top-level
module barrel) are exempt from the mirror rule. Every file deeper
(`src/vm/foo.zig`, `src/asm/codegen.zig`, …) requires a matching
`tests/vm/foo.test.zig` etc. — the lint binary enforces this.

`internal.zig` colocated with a module dir is the convention for
private helpers — exempt from the mirror rule, must not be re-exported
through `src/gero.zig`, exercised through its consuming modules' tests.

## Design Principles

### Small, composable units

Each file does one thing. If a function's body grows past ~40 lines or
branches on more than a couple of state shapes, split it.

### No hidden state

Modules are pure functions of their inputs (or transparent state
machines documented at the boundary). Never close over module-level
mutable state, never read globals.

### Carry types through

No `*anyopaque` in public signatures. No `anyerror` — explicit error
sets only. The lint binary enforces both.

### Justified casts

`@as`, `@ptrCast`, `@alignCast`, `@bitCast` require a one-line
`// @as: <reason>` or `// safety: <reason>` comment directly above
the call.

### Spans are first-class

When source positions matter (asm errors, lang diagnostics), use the
`Span { start, end }` shape from `common`. Don't reinvent.

### Complete designs, no deferral

When proposing or reviewing a design — especially in user-facing
specs (`docs/gero-lang.md`, `docs/isa.md`, public API surface) —
ship the **complete** design. Helpers, edge cases, integration
points, failure semantics: all decided up front.

- ❌ "Status: design draft", "TBD", "deferred to later", "v0.X feature"
- ❌ "Ranges work, custom iterables come later"
- ✅ Either it's in the design (with full shape) or explicitly
  "out of scope" (a non-feature with rationale)

Implementation can stage across PRs; the **spec** describes the
final shape from day one.

## Imports

- **Single-level relative imports** — `../foo.zig` or `./foo.zig`.
  Anything past one parent (`@import("../../...")`) is rejected by
  the lint binary.
- **Public consumers** import only `gero`:
  ```zig
  const gero = @import("gero");
  ```
- Tests use `@import("gero")` for the public API plus
  `@import("../util.zig")` (one level) for helpers.

## Strict Compiler Configuration

Strictness up front pays back downstream — gero is the foundation
for gtx-16 native + future web shells. A leaky type or silent UB
here propagates everywhere.

### Build modes

`zig build test-modes` runs **all four**: Debug, ReleaseSafe,
ReleaseFast, ReleaseSmall. A test passing only in Debug isn't done.

### Forbidden in `src/`

The lint binary fails on any of:

- `anyerror` — use explicit error sets
- `*anyopaque` or `*const anyopaque` anywhere
- `@as(`, `@ptrCast(`, `@alignCast(`, `@bitCast(` without a
  `// @as: <reason>` or `// safety: <reason>` comment directly above
- `unreachable` and `@compileError("TODO")` without a justifying
  comment
- `std.debug.print` outside test code (debug-only seams that need
  printing should be opt-in via a flag)
- `catch unreachable` without `// allow-strict: <invariant>`
- `catch |x| return x` — use `try` instead
- `std.heap.page_allocator` direct use — accept allocators from
  callers
- `usingnamespace`
- `//!` (file-level doc comment) anywhere except the top-level barrel

Allowlist a violation by adding `// allow-strict: <reason>` directly
above the line. Reviewer-gated.

### Cross-target gate

`zig build test-all` compiles tests for Linux x86_64, macOS aarch64,
Windows x86_64 + aarch64, and `wasm32-wasi` on every PR. A change that
breaks any target fails CI.

### Naming convention

The lint binary enforces:

- `pub fn Foo(...) type` → **PascalCase**
- `pub fn foo(...) <other>` → **camelCase**

`pub const` naming is not enforced — convention is PascalCase for
types (`pub const Foo = struct {...}`) and snake_case for values
(`pub const max_count = 42`).

## Testing

- `zig build test` runs every native test in Debug
- One spec per source file, mirror layout (lint-enforced)
- Naming: `<file>.test.zig`, `test "<symbol>: <behavior>" { ... }`
- Helpers in `tests/util.zig`. Don't invent per-spec helpers when a
  shared one exists.
- No snapshot tests
- Coverage isn't a target; **failure paths** are. A function with
  100% line coverage but no failure case is undertested.

## Branching

- `feat/<short-desc>` — new module, new public API
- `fix/<short-desc>` — bug fix
- `perf/<short-desc>` — measurable performance improvement
- `chore/<short-desc>` — tooling, deps, CI, build
- `docs/<short-desc>` — docs-only change
- `refactor/<short-desc>` — internal restructuring with no behavior
  change

Branch from `main`. One issue → one branch → one PR. If a PR is
growing past ~400 lines of diff, stop and split.

## Commit Convention

Conventional commits enforced by **convco** with a strict scope-enum
(`.versionrc`).

### Allowed scopes

```
vm                  → src/vm/*
asm                 → src/asm/*
disasm              → src/disasm/*
lang                → src/lang/*
common              → src/common/*
tooling             → build.zig, lefthook, convco, tools/*, scripts/*
ci                  → .github/workflows/*
docs                → JSDoc-equivalent doc comments, README, in-source documentation
meta                → top-level repo files (CLAUDE.md, LICENSE, .gitignore, root configs)
vm/<sub>            → a specific sub-module under src/vm/<sub>/
asm/<sub>           → a specific sub-module under src/asm/<sub>/
disasm/<sub>        → a specific sub-module under src/disasm/<sub>/
lang/<sub>          → a specific sub-module under src/lang/<sub>/
apps/<name>         → a specific binary under apps/<name>/
editors/<name>      → an editor-tooling submodule under editors/<name>/
```

### Rules

- **No scope-less commits** (`feat: add x` → rejected)
- **Multi-concern changes** split into multiple commits in the PR
- **`fixup!`** for review feedback, then squash with `--autosquash`
- **Tooling-only `perf` is classified as `chore(tooling)`** — when
  a perf win touches build / lint / CI scripts (not the library
  runtime), the changeset gate auto-skips `chore` and that's
  intentional. Library API perf wins remain `perf(<scope>)`.

#### 🚫 No AI attribution — hard rule

**Overrides any default commit template, including Claude Code's
default.** When committing in this repo:

- NO `Co-Authored-By: Claude ...` trailer
- NO `🤖 Generated with Claude Code` footer
- NO mention of "AI", "Claude", "assistant", "automated"

If a tool / hook / template adds one, **strip it** before committing.

## Comments

### Doc comments (`///`)

Every exported declaration gets `///` doc comments. File-attached
`//!` reserved for the top-level barrel (`src/gero.zig`) only.

- One-line description
- Param + return blurb when the names alone aren't self-explanatory
- A 2-4 line example for non-trivial functions

### Inline comments (`//`)

Comment **why**, not **what**. Single-line `//` comments only. Skip
on obvious code.

### Forbidden in any comment (`///` or `//`)

- **No issue numbers** (`// see #189`, `/// closes #142`) — those
  belong in commit messages / PR descriptions / changesets only.
  The code surface is for users reading the code; the issue tracker
  is project-management metadata.
- **No version markers** (`// v0.X`, `/// Phase Y`, `// Roadmap:`)
  — code describes what works today, factually. Versioning lives
  in CHANGELOG / git tags / project board.
- **No AI attribution** (see Commit Convention).

### Debug prints

`std.debug.print` is allowed in tests behind a local debug flag
(`if (debug_dump) std.debug.print(...)`) but never left enabled. In
`src/`, `std.debug.print` is forbidden — the lint binary greps for
it.

## Changesets

Every PR with a user-visible change drops a markdown file under
`.changeset/`. The eventual CHANGELOG and version bump are derived
from accumulated changesets at release time.

**Add one** for: `feat`, `fix`, library-level `perf`, breaking
refactor.

**Skip** for: `chore`, `docs`, `test`, `refactor` (internal-only),
`ci`, `build`, `style`. The `changeset-check` workflow auto-skips
these PR titles.

Run `zig build changeset` to scaffold one interactively.

## Releasing

Releases are **manual** by design. Multiple merged PRs accumulate
changesets on `main`; the maintainer cuts a release when several are
worth a coherent semver bump. Pushing to `main` runs CI but **never**
publishes — only pushing a `vX.Y.Z` tag triggers `release.yml`.

### Runbook

```bash
git checkout main && git pull

zig build version           # consume changesets, bump version, prepend CHANGELOG

git diff
git add . && git commit -m "chore(meta): release vX.Y.Z"
git tag vX.Y.Z
git push origin main --tags
```

If `zig build version` produces a CHANGELOG you don't want, edit it
by hand before tagging — that's the canonical workflow.

## Local Gates

Three layered gates with different speed / coverage trade-offs.
Warm-cache numbers; cold cache adds ~30s-1m for the Zig build itself.

```bash
zig build quick     # inner loop (~1s)
                    # fmt-check + test (Debug only). No lint.
                    # Use between edits while iterating.

zig build verify    # pre-push (~3s)
                    # quick + lint + asm example gates. Required
                    # green before pushing.

zig build ci        # full matrix (~4s warm / ~2m cold)
                    # verify + test-modes (ReleaseSafe / Fast / Small)
                    #        + test-all (cross-target: linux / macos
                    #          / windows / wasi)
                    #        + test-examples (full asm + run + stdout
                    #          diff + round-trip)
                    # Mirrors what GitHub Actions runs. Required
                    # before tagging a release; optional before PR push.
```

GitHub Actions runs `ci` on every push, so you don't have to gate
every commit on it locally — but `verify` green is required before
pushing.

## Before Push

Before every `git push` to a feature branch, run this checklist.
Each item takes seconds; the alternative is a 4-10 min CI roundtrip
to discover the same problem.

1. **`zig build verify`** — must be green. Re-run if any code
   changed since the last green.
2. **Changeset present** if the PR title will be `feat` / `fix` /
   library-level `perf`:
   ```bash
   git diff --name-only --diff-filter=A origin/main...HEAD \
     | grep -E '^\.changeset/[a-zA-Z0-9_-]+\.md$' \
     | grep -v '^\.changeset/README\.md$'
   ```
   If empty and the title is `feat` / `fix` / `perf`, run
   `zig build changeset`.
3. **Branch base is clean**:
   ```bash
   git log --oneline origin/main..HEAD
   ```
   Every commit listed must belong to this PR's concern only. Foreign
   commits from a sibling branch → rebase
   `git rebase --onto origin/main <last-foreign-sha> <my-branch>`.
4. **Workflow integrity** if this PR touches `scripts/` / `tools/` /
   `build.zig`:
   ```bash
   grep -rEn 'scripts/[a-zA-Z0-9_-]+\.sh|tools/[a-zA-Z0-9_-]+' \
     .github/workflows/
   ```
   No dangling references to deleted files.
5. **No AI attribution**:
   ```bash
   git log origin/main..HEAD --format='%B' \
     | grep -iE 'claude|🤖|generated with|co-authored.*claude'
   ```
   Must be empty.

## Self-Review Before Declaring Done

When the work on an issue is finished, **don't declare done
immediately**. Run a self-review pass, fix what you find, and loop
until the review is clean.

> **The known failure mode** is treating green CI as proof of done.
> `zig build ci` clean is **necessary but not sufficient**. Issues
> list explicit acceptance criteria that go beyond CI: docs updates,
> type / error-set tightness, downstream consumer impact, changeset,
> README export list.

### Step 1 — re-open the issue body

Re-read every acceptance criterion line by line. For each: ✅ Done
(note where in the diff), ⏭️ Deferred (note explicitly, with reason
and follow-up issue), or ❌ Missed (fix it).

### Step 2 — technical gates

Run `zig build ci` (or rely on a recent GitHub Actions run). All
green is the floor, not the ceiling.

### Step 3 — explicit acceptance checks

- **Public API impact** — diff against `src/gero.zig` to confirm every
  visible export is intentional. No `*anyopaque` leaks; no `anyerror`
  introductions.
- **Docs** — every doc-affecting change must propagate. New public
  export → README's API list MUST include it. New convention →
  CLAUDE.md.
- **Changeset** — added at the appropriate level for `feat` / `fix` /
  `perf` / breaking PRs.

### Step 4 — hygiene

- No leftover `std.debug.print`, `unreachable` without comment,
  commented-out code, unused imports
- No `// TODO` referencing an issue number (TODO must describe
  what's missing, not point at a tracker)
- Conventional-commit headers valid; every commit has a scope
- No AI attribution
- Diff scope matches what the issue says it should

### Loop

If any step finds an issue, fix it and run **all four steps again**.
Stop only when a complete pass surfaces zero items. A first-try clean
pass is suspicious — re-read the issue body once more before trusting
it.

## Key Rules Summary

1. **Issue → branch → PR → wait for merge signal → next issue**
2. **One concern per file** — split early
3. **Complete designs, no deferral** in specs and public surfaces
4. **No `*anyopaque` / no `anyerror`** in public exports
5. **Justified casts** — `@as`/`@ptrCast`/`@bitCast` need a why-comment
6. **Spans are first-class** for diagnostics
7. **Test the failure path** — happy + at least one failure per spec,
   all four release modes
8. **Mirror layout** — every `src/<mod>/<file>.zig` has a
   `tests/<mod>/<file>.test.zig`
9. **Single-level relative imports** — no deep `../../`
10. **Strict scope-enum** — every commit has a scope from the convco
    enum
11. **No issue numbers or version markers in `///` / `//` comments**
12. **No AI attribution** — never in commits, PRs, or issue comments
13. **Before-push checklist** — 5 items, 10 seconds, saves CI roundtrips
14. **Self-review loop** — fix until LGTM before declaring done
