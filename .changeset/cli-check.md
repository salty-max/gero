---
bump: patch
---

`gero check` now ships — runs the full assembler pipeline
(resolve includes → parse → codegen-validate) without writing a
`.gx`. Positional args can be individual files **or directories
(walked recursively for `*.gas`)** and any mix of the two. Single-
file invocations get a `gero asm`-style rich summary
(`✓ <path>  (N bytes, M banks)` + `Finished in X ms` footer +
optional `--verbose` per-phase timings); multi-file walks print
one `✓` / `✗` line per file plus a `check: N files passed, M
failures` summary. Caret-style diagnostics appear on every failure.
`--quiet` suppresses the per-file ok lines + summary. Exit codes
per cli.md §3.9 + §5: `0` clean, `4` on any diagnostic, `1` on
host IO, `2` on usage. `.gr` sources route to a "not yet
implemented" stub until v0.3 wires the gero-lang front-end.

A `zig build check-examples` step drives every `examples/asm/*.gas`
(recursive — banks/ included) through `gero check` and is wired
into `zig build ci` alongside the existing `test-examples`.
