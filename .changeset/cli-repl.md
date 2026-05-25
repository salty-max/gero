---
bump: minor
---

`gero repl` ships — an interactive gero-lang prompt that reads
lines from stdin, classifies each input (top-level decl /
prelude binding / per-iteration body), compiles the assembled
session on every submit, and runs the result on a fresh VM.
Closes #223.

Input classification:

- `def` / `class` / `struct` / `enum` / `use` / `bake def` /
  `@ann` → module-scope declaration; persists across the
  session.
- `let` / `const` → re-run on every subsequent input so the
  binding stays visible.
- Everything else → one-shot body statement in the synthesized
  `__repl_main`. Bare expressions auto-wrap in `print` so the
  value lands on stdout; `name(args)` calls don't wrap (their
  own `print`s surface the result).

Multi-line continuation uses lex-only block-balance — `def` /
`do` / `if` / `while` / `for` / `repeat` / `class` / `struct` /
`enum` / `match` openers must match `end` / `until` closers
before the input compiles. Strings + line comments are skipped
in the count.

Meta-commands: `.help`, `.quit` / `.exit`, `.reset`, `.dump
<name>`. Parse / typecheck / codegen failures print diagnostics
and leave the session source untouched so the prompt survives
mistakes.

Wired through `apps/gero-cli/{main,cli}.zig`; `docs/cli.md`
§3.13 documents the surface.
