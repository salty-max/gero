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

One-liner submissions like `def add(x, y) return x + y end`,
`while n < 3 print n n = n + 1 end`, `if x > 0 print "pos" end`,
or `for i in 0..5 print i end` now work: the REPL iteratively
pre-parses the input, finds every "expected newline" boundary
the parser flags, and injects `\n` in-place before the main
pipeline runs. Re-parsing between passes catches boundaries the
parser couldn't see past the first one (recovery skips ahead).
The canonical multi-line form is what gets committed to the
session source, so subsequent prompts see valid newline-
significant gero-lang.

Up / Down arrows now recall previous prompts, shell-style. The
REPL flips stdin into raw mode while reading each line so it
can intercept arrow-key escape sequences, and restores cooked
mode while the compiled program runs. Backspace, Ctrl-C
(cancel the current line), and Ctrl-D (EOF on empty) all work
as expected. Non-TTY input (piped scripts, CI captures) falls
back to the cooked line-buffered reader so test harnesses keep
working unchanged.
