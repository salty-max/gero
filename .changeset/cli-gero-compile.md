---
bump: minor
---

`gero compile <file.gr>` is wired end-to-end: resolves `use
"..."` imports, tokenizes, parses, type-checks, lowers, writes
a `.gx` archive next to the source (or to `--out <path>` when
given).

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

Closes #198.
