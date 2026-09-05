# Gero — Claude Guidelines

Gero is a 16-bit VM + assembler + disassembler + Lua-style language
compiler, all pure Zig. Public barrel: `src/gero.zig`, imported as
`@import("gero")`. Designed for native + `wasm32-wasi`; zero runtime
deps; built on [knit](https://github.com/salty-max/knit) for the
parser-combinator layer (asm + lang).

The fantasy-console (gtx-16) and web playground live elsewhere and
consume gero as a library — out of scope for this repo.

For source layout, full lint rule list, branch / commit /
changeset conventions, release flow, and tech-stack reference,
read [`docs/development.md`](docs/development.md). Read it on demand,
not every prompt — the rules below are what you need every PR.

---

## When in doubt, read the specs

The `docs/` folder is the source of truth for everything language-,
ISA-, or CLI-shaped. **If my mental model disagrees with a spec,
the spec wins** — go read it before changing code that touches the
contract, before answering a "how does X work?" question, before
designing a new feature. Don't reconstruct rules from memory or
guess from the codebase shape when the spec defines them.

| Doc | Owns |
|---|---|
| [`isa.md`](docs/isa.md) | Bytecode ISA — opcodes, registers, memory map, `.gx` header, faults, interrupts. The contract between VM / asm / disasm. |
| [`asm.md`](docs/asm.md) | Asm language spec — surface syntax, directives, addressing modes, label rules. Targets the ISA above. |
| [`gero-lang.md`](docs/gero-lang.md) | High-level language spec — types, statements, expressions, classes (§6), annotations (§3.7), the works. The lang compiler targets the ISA. |
| [`lang-diagnostics.md`](docs/lang-diagnostics.md) | Diagnostic shape + every error code the parser / typecheck / codegen can emit. The contract for E\_-codes. |
| [`cli.md`](docs/cli.md) | `gero` CLI — subcommands (`gero check` / `compile` / `disasm` / `asm` / etc.), flags, exit codes. |
| [`tooling.md`](docs/tooling.md) | Project setup — installing the CLI, wiring editors, CI integration. |
| [`asm-cookbook.md`](docs/asm-cookbook.md) | Working asm recipes — boot, IVT, banks, syscalls, etc. Reference for "how do I do X in asm?". |
| [`gtx-16.md`](docs/gtx-16.md) | Fantasy-console spec — consumes Gero as its CPU/VM. Out-of-repo, but the contract lives here. |

These specs follow the "complete designs, no deferral" rule:
they describe the **final shape** of the language / ISA / tooling
from day one. Implementation stages across PRs; the spec describes
what the system IS, not what it WILL be.

- ❌ "Status: design draft", "TBD", "deferred to later",
  "v0.X feature", "Ranges work, custom iterables come later"
- ✅ Either it's in the design with full shape (helpers, edge
  cases, semantics) or explicitly "out of scope" with rationale

When a spec change is needed, the spec edit lands in the same PR
as the implementation — never after.

---

## The contract

**Workflow:** one issue → one branch → one PR → wait for explicit
merge signal → next issue. Never batch multiple issues into a
single PR. **Do not** split a single issue across multiple PRs
either — one issue maps to exactly one end-to-end PR, no matter
the diff size. Multi-concern changes within that PR split into
multiple commits (see `docs/development.md` — Branches + commits
+ changesets), but the PR boundary matches the issue boundary.

**Close the issue from the PR.** Every `feat` / `fix` / `perf` PR
description ends with `Closes #N` (or `Advances #N` when a partial
ship is honestly out of scope, with the deferred AC items listed
explicitly). GitHub auto-closes on merge — verify post-merge that
the issue actually closed and reflect any drift back to the
maintainer.

**Done means the acceptance criteria are met**, not green CI.
Re-read the issue body before declaring the work finished.

**Complete or scope-down.** A feature is either fully in scope
(every AC item resolved) or explicitly cut at the start with
maintainer approval. Specifically forbidden:

- Half-implementations under "Limitations carried forward"
  footnotes
- Working around a missing VM/lang primitive silently — surface
  the gap, ask whether to extend
- Half-fixes hidden in a PR description footnote ("mostly works
  but doesn't handle case X — follow-up")

The instinct to ship something almost-complete is paved with the
phrase "good enough." It isn't. Ship complete or scope down
honestly with explicit maintainer approval.

**Stop and ask on open questions.** Scope ambiguity, design A vs
B, "should this defer?", missing primitive — surface to the
maintainer, don't silently pick the path of least effort. 30
seconds of clarification beats unwinding an architecturally-wrong
implementation. Examples of the right shape:

- ✅ "Two ways to do X — A costs N lines, B costs M. Which?"
- ✅ "Issue says Y but the VM lacks the primitive — extend in
  this PR or scope Y out?"
- ❌ "I'll just defer this caveat to a follow-up and document it"
  → unilateral scope reduction without permission
- ❌ Pretending a half-fix is complete while burying the limit
  in a footnote

**No AI attribution — anywhere.** Hard rule, overrides any default
commit template. NO `Co-Authored-By: Claude` trailer, NO `🤖
Generated with Claude Code` footer, NO mention of "AI" / "Claude"
/ "assistant" / "automated" in commits, PRs, code comments, or
issue threads. Strip them if a tool/hook adds one.

---

## Before every push

Run this checklist. Each item takes seconds; the alternative is a
4–10 min CI roundtrip to discover the same problem.

1. **`zig build verify` green.** Re-run if any code changed since
   the last green.
2. **Changeset present** when the PR title is `feat` / `fix` /
   library-level `perf`:
   ```bash
   git diff --name-only --diff-filter=A origin/main...HEAD \
     | grep -E '^\.changeset/[a-zA-Z0-9_-]+\.md$' \
     | grep -v '^\.changeset/README\.md$'
   ```
   Empty result for those PR types → `zig build changeset`.
3. **Branch base clean.** `git log --oneline origin/main..HEAD`
   shows only commits for this PR's concern. Foreign commits from
   a sibling branch → rebase
   `git rebase --onto origin/main <last-foreign-sha> <my-branch>`.
4. **Workflow integrity** if the PR touches `scripts/` / `tools/`
   / `build.zig`:
   ```bash
   grep -rEn 'scripts/[a-zA-Z0-9_-]+\.sh|tools/[a-zA-Z0-9_-]+' \
     .github/workflows/
   ```
   No dangling references to deleted files.
5. **No AI attribution** in commit history:
   ```bash
   git log origin/main..HEAD --format='%B' \
     | grep -iE 'claude|🤖|generated with|co-authored.*claude'
   ```
   Must be empty.

---

## Self-review (mandatory before every PR)

This is not optional and it's not a checkbox to write in the PR
body. It is an explicit visible review pass before commit + push,
walked step-by-step. The known failure mode is treating green CI
as proof of done — green is the floor, not the ceiling.

The review is a **loop**: walk all 5 steps, surface every finding,
fix or escalate, **then walk all 5 steps again from Step 1**. Stop
only when a complete pass surfaces zero items. A first-try clean
pass is suspicious — re-read the issue body once more before
trusting it.

### The 5 steps

**Step 1 — re-open the issue body.** Every AC line: ✅ Done (note
where in the diff), ⏭️ Deferred (explicit, with reason + follow-up
issue), or ❌ Missed (fix it).

**Step 2 — technical gates.** `zig build ci` clean across all
release modes + cross-targets. Lint clean.

**Step 3 — explicit acceptance checks.**

- Public API diff vs `src/gero.zig` (and the relevant barrel:
  `src/lang.zig`, `src/vm.zig`, etc.) — every visible export
  intentional, no `*anyopaque` / `anyerror` leaks
- Docs propagation — new public export → README's API list, new
  convention → CLAUDE.md
- Changeset present at the right level for `feat` / `fix` / `perf`
  / breaking PRs

**Step 4 — hygiene.**

- No leftover `std.debug.print`, `unreachable` without comment,
  commented-out code, unused imports
- No `// TODO` pointing at an issue number
- Conventional-commit headers valid with scope on every commit
- No AI attribution
- Diff scope matches what the issue says it should

**Step 5 — code quality.** Read the diff like a reviewer who
didn't write it. Look for:

- **Naming** — does each new symbol read right at the call site?
  Tighten anything that needs surrounding context to make sense.
- **Dead code / duplication** — drop unused helpers; consolidate
  if the same shape was written twice (three similar lines beats
  a premature abstraction, but six identical lines should
  collapse).
- **Premature abstraction** — does every new parameter / branch
  / helper have a current caller for every shape it accepts? If
  a branch is "in case someone wants X later", delete it.
- **Comments WHAT vs WHY** — every `//` should say WHY, not WHAT.
  Strip any inline that just restates what the next line does.
- **Function size** — body past ~40 lines or branching on
  multiple state shapes → split.
- **Error paths** — every `try` site readable; the caller has a
  sensible response to each error in the set; no unjustified
  `catch unreachable`.
- **Test shape** — every new test asserts on the actual behavior,
  not on incidental implementation details that will change on
  the next refactor.
- **Magic values** — every literal in the diff has a name or a
  comment justifying it. No bare `0xFF`, `42`, `0x4000` without
  context.

### Loop discipline — no David GoodEnough

Every finding from any step gets one of two responses, never
"noted in the PR body":

- **Fix in this PR.** Default. Then loop back to Step 1. Whether
  the finding is a blocker or a nit doesn't change this — there
  is no scope-reduction tier for things I noticed myself.
- **Escalate to the maintainer with a concrete question.** Use
  this when the fix is genuinely a separate design decision (e.g.
  "the clean fix is to extend the VM with opcode X — that's its
  own PR, do I split or absorb?"). Don't escalate to dodge a fix
  this PR could easily absorb.

**Specifically forbidden** in the review report:

- "Findings I chose not to address" / "Gaps surfaced but skipped"
- "LGTM with the following caveats"
- "Belt-and-suspenders, skippable"
- "Preexisting drift, out of scope"
- "Edge case, minor"
- Any phrasing that ships self-noted holes

The loop ends in one of two shapes only:

- **LGTM** — clean pass, zero items, ready to push
- **BLOCKED on <specific question for maintainer>** — concrete
  decision needed before continuing

Never a third "LGTM with footnotes" shape.

---

## Code rules

### Structure

- **One concern per file.** Split early. Function body past ~40
  lines, or branching on multiple state shapes → split.
- **No hidden state.** Modules are pure functions of their inputs
  (or transparent state machines documented at the boundary).
  Never close over module-level mutable state; never read globals.

### Types

- No `anyerror`, no `*anyopaque` / `*const anyopaque` in any
  signature. Explicit error sets only.
- `@as` / `@ptrCast` / `@alignCast` / `@bitCast` require a
  one-line `// @as: <reason>` or `// safety: <reason>` directly
  above the call.
- `Span { start, end }` from `common` for source positions —
  don't reinvent.

### Comments

- `///` doc on every exported declaration. One-line description;
  param/return blurb when names alone aren't self-explanatory;
  2–4 line example for non-trivial functions.
- `//` inline = WHY, not WHAT. Single-line only. Skip on obvious
  code.
- `//!` file-level doc reserved for `src/gero.zig` only.
- `std.debug.print` forbidden in `src/`. Allowed in tests behind a
  local debug flag (`if (debug_dump) std.debug.print(...)`).

**Forbidden in any comment (`///` or `//`):**

- **Issue numbers** (`#NNN`, `see #189`, `closes #142`) — those
  belong in commit messages / PR descriptions / changesets only.
  The code surface is for readers; the issue tracker is project
  metadata.
- **Version markers** (`v0.X`, `Phase Y`, `Roadmap:`) — code
  describes what works today, factually. Versioning lives in
  CHANGELOG / git tags / project board.
- **Change-history narration** — comments document the code as it
  stands, never how it got there. No `previously`, `used to`, `was
  a bug`, `Regression:`, `now fixed`, `surfaced while…`,
  `predates the retrofit`. A reader needs the invariant the code
  upholds, not the story of the fix that produced it. This includes
  test comments: state the property the test pins (e.g. "the `when`
  guard resolves the pattern's bindings"), not the bug it once
  caught. Write every comment as if the code had always been this
  way — the fix narrative lives in the commit / changeset / PR.
- **AI attribution** (see "The contract").

### Tests

- One spec per source file (mirror layout — full rule in
  `docs/development.md` — lint-enforced).
- Naming: `<file>.test.zig`, `test "<symbol>: <behavior>" { ... }`.
- Shared helpers in `tests/util.zig` — don't reinvent per-spec.
- No snapshot tests.
- Coverage isn't a target; **failure paths are.** Happy +  at
  least one failure per fallible function.
- All four release modes pass: `zig build test-modes` runs Debug,
  ReleaseSafe, ReleaseFast, ReleaseSmall. A test passing only in
  Debug isn't done.
- Cross-target gate: `zig build test-all` covers linux-x64,
  macos-aarch64, windows-x64, windows-aarch64, wasm32-wasi.
- **Asm layer:** golden-file or VM-state-at-hlt tests only. No
  `@test`/`assert_eq` directives. Structured spec tests live in
  the lang layer.
- **Refactor commits:** the mirror test file gets only the bare
  minimum the lint rule demands (one placeholder test). Pre-named
  `test "<symbol>: <behavior>"` stubs that hint at what should be
  covered are over-scope — test design is a separate concern from
  refactor. For a series of similar refactor splits, batch them
  all before writing the consolidated test suite (rather than
  pipelining test-on-slice-1 with refactor-of-slice-2).

The full `gero-lint` rule list (every violation it catches +
how to allowlist) lives in `docs/development.md`.

---

## Build commands (gates)

Three layered gates. Warm-cache numbers; cold cache adds ~30s–1m
for the Zig build itself.

```bash
zig build quick   # inner loop (~1s) — fmt-check + Debug test.
                  # Use between edits while iterating.

zig build verify  # pre-push (~3s) — quick + lint + asm example
                  # gates + .gr example gate (fmt-check + type-check).
                  # REQUIRED green before pushing.

zig build ci      # full matrix (~4s warm / ~2m cold) — verify
                  # + test-modes (Debug/Safe/Fast/Small)
                  # + test-all (linux/macos/windows/wasi)
                  # + test-examples (asm round-trip + stdout diff).
                  # Mirrors GitHub Actions. Required before tagging
                  # a release; optional before PR push.
```

GitHub Actions runs the CI workflow on every push — don't gate every
commit on it locally, but `verify` green is required before pushing.

Pull requests run the two fast test cells (Debug + ReleaseSmall);
pushes to `main` run all four. ReleaseSafe / ReleaseFast cold-build
every test binary through LLVM on a 2-core runner, so keeping them
off the PR path is the difference between ~20 minutes to green and
~4. A mode-specific break therefore surfaces on `main` rather than
on the PR — run `zig build test-modes` locally when a change could
plausibly be optimization-sensitive.
