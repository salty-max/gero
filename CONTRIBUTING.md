# Contributing to gero

Thanks for thinking of contributing! gero is a small but
rigorously-tooled project — the conventions below exist so every
change keeps the bar consistent.

## Toolchain

| Tool | Purpose | Install |
|------|---------|---------|
| **Zig 0.16.0** | Compiler + task runner | https://ziglang.org/download/ |
| **lefthook** | Git hooks | `brew install lefthook` |
| **convco** | Conventional-commit validator | `brew install convco` |

Zero Node, zero Bun, zero npm. Everything else (build, test, lint,
changesets, release) is `zig build <step>` with bash helpers under
`scripts/`.

After cloning:

```bash
lefthook install
zig build       # builds zig-out/bin/gero — required for the .gas pre-commit hooks
zig build ci    # full local pipeline: lint + 4 release modes + cross-target compile + examples
```

If `zig build ci` is green, you're set up correctly. The pre-commit
hooks shell out to `./zig-out/bin/gero check / fmt --check` on
staged `.gas` files; keep the binary built (`zig build`) before
committing.

## Branching

| Prefix | When |
|--------|------|
| `feat/<short-desc>` | new module, new public API |
| `fix/<short-desc>` | bug fix |
| `chore/<short-desc>` | tooling, deps, CI, build |
| `docs/<short-desc>` | docs-only change |
| `refactor/<short-desc>` | internal restructuring with no behavior change |

Branch from `main`. One issue → one branch → one PR. If a PR is
growing past ~400 lines of diff, stop and split.

## Commit convention

Conventional commits, validated by **convco** with a strict
scope-enum (`.versionrc`). Scope is mandatory.

### Allowed scopes

```
vm                  → src/vm/*
asm                 → src/asm/*
disasm              → src/disasm/*
lang                → src/lang/*
common              → src/common/*
tooling             → build.zig, lefthook, convco, scripts/*
ci                  → .github/workflows/*
docs                → doc comments, README, in-source documentation
meta                → top-level repo files (LICENSE, .gitignore, root configs)
vm/<sub>            → sub-module under src/vm/<sub>/
asm/<sub>           → sub-module under src/asm/<sub>/
disasm/<sub>        → sub-module under src/disasm/<sub>/
lang/<sub>          → sub-module under src/lang/<sub>/
apps/<name>         → binary under apps/<name>/
```

### Examples

```
feat(vm): add register file + initial dispatch loop
fix(asm/codegen): emit BR instead of BR0 for unconditional jumps
refactor(common): extract Span into its own file
chore(deps): bump zig minimum to 0.16.1
docs(lang): clarify the type system positions
ci: cache zig install across jobs
```

## Changesets

Every PR with a user-visible change drops a markdown file under
`.changeset/`. Use `zig build changeset` to scaffold one
interactively.

Skip for `chore`/`docs`/`test`/`refactor`/`ci`/`build`/`style` —
the `changeset-check` workflow auto-skips those titles.

See [.changeset/README.md](./.changeset/README.md) for the format.

## Test layout

`tests/` mirrors `src/`. Every `src/<module>/<file>.zig` has a
matching `tests/<module>/<file>.test.zig`. The mirror is enforced by
`scripts/check-mirror.sh`; CI fails on a missing test file.

Tests should:
- Cover the happy path
- Cover **at least one** failure case (wrong input, EOF, etc.)
- Use `std.testing.allocator` for any test that allocates (the
  `check-testing-allocator.sh` lint enforces this)

Helpers live in `tests/util.zig`. Imported as `@import("util")`.

## Self-review loop (required)

Before declaring a non-trivial task done, walk this checklist; if any
step finds something, fix it and re-run **all** steps.

### Step 1 — re-read the issue body

Walk the acceptance criteria line by line. Each one is either ✅ Done
(note where in the diff), ⏭️ Deferred (note explicitly with a reason
and follow-up issue), or ❌ Missed (fix it).

### Step 2 — technical gates

```bash
zig build ci
```

If `zig build ci` isn't green locally, the PR isn't ready. CI is the
safety net, not the iteration loop.

### Step 3 — code-quality / language-idioms

Walk every line of the diff with two lenses:

- Idiomatic Zig? No `*anyopaque`, no `anyerror`, justified casts
  (`// @as: ...` / `// safety: ...`), no `catch unreachable` without
  `// allow-strict: ...`, no `usingnamespace`.
- Edge cases handled? Failure paths loud? Cross-target portability?

### Step 4 — hygiene

- No leftover `std.debug.print` in `src/`
- No `// TODO` without an issue link
- Conventional-commit headers valid; every commit has a scope
- Diff scoped to what the issue says — drive-by refactors go in their
  own PR
- Changeset added if appropriate

## Where to ask questions

- Open a GitHub issue for bugs and feature requests
- For contribution scope or design questions on a specific issue,
  comment on the issue itself
