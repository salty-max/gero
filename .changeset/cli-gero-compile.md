---
bump: minor
---

`gero compile <file.gr>` is wired end-to-end: resolves `use
"..."` imports, tokenizes, parses, type-checks, lowers, writes
a `.gx` archive. Output precedence: `--out <path>` wins; else
`<project_root>/<[build].out>/<optimize>/<basename>.gx` when a
`gero.toml` exists in an ancestor (mirrors `gero build`'s
Cargo-style layout, creates the profile dir on demand); else
sibling-default next to the source. A malformed manifest exits 3
rather than silently falling back.

Multi-file is real — `use "./util"` recursively loads each
referenced `.gr` (with `.gr` extension auto-added when missing),
fuses sources into one buffer + `SourceMap`, and threads the
spans through every later phase so diagnostics still render
against the right file with caret context.

Include-phase errors (cycle / depth-exceeded / not-found) get
their own diagnostic codes — `E_USE_CYCLE`, `E_USE_DEPTH`,
`E_USE_NOT_FOUND`.

Exit codes per cli.md §5: 0 clean, 1 host IO, 2 usage, 3 parse
error, 4 type error.

Re-exports surfaced on `gero.lang`: `resolveUseImports`,
`FusedSource`, `SourceMap`, `FileInfo`, `Located`,
`IncludeError`, `IncludeErrorKind`.

`gero run` now wires `vm.host.out` to stdout so the lang's
`print` (which lowers to `sys print_str` / `print_int` /
`print_char` / `print_newline`) actually surfaces in the
terminal. Previously those syscalls were silently no-op'd —
only `gero asm`'s `int $10` print syscall reached stdout, so
nothing produced by `gero compile` was demoable. The asm-level
intercept stays in place untouched.

Closes #198.
