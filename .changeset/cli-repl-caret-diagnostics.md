---
bump: patch
---

`gero repl` now renders parse / typecheck / codegen errors with
caret-style source snippets via `gero.lang.render.prettyOne`,
matching the output `gero check` produces. Lexer + parser
errors flow through the same `Diagnostic` shape, so secondary
spans (e.g. "expected `bool` because of this annotation") show
under the offending line. Warnings render but no longer block
the session — the program still runs.

Banner + prompt picked up a touch of color: bold cyan `gero
repl` heading, dim version line, bold cyan `>>>` prompt, dim
`...` continuation. All ANSI escapes gate on the existing
color-detection flow, so non-TTY output stays plain.
