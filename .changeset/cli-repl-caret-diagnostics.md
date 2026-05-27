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

Diagnostic spans translate back to the user's literal input so
the snippet shows exactly what the user typed — no synthetic
`__repl_main` wrapper, no auto-`print` prefix, line numbers
relative to the input. Diagnostics whose spans fall outside the
new input are filtered.

Banner + prompt picked up a touch of color: bold cyan `gero
repl` heading, dim version line, bold cyan `>>>` prompt, dim
`...` continuation. All ANSI escapes gate on the existing
color-detection flow, so non-TTY output stays plain.

One-liner submissions like `def add(x, y) return x + y end`
now work: the REPL pre-parses the input, finds every "expected
newline" boundary the parser flags, and injects `\n` in-place
before the main pipeline runs. The canonical multi-line form
is what gets committed to the session source, so subsequent
prompts see valid newline-significant gero-lang.
