---
bump: patch
---

`gero check <file.gas>` now ships — runs the full assembler
pipeline (resolve includes → parse → codegen-validate) without
writing a `.gx`. Reports caret-style diagnostics on failure;
on success, a `gero asm`-style summary line `✓ <path> (N bytes,
M banks)` plus a Cargo-style `Finished in X ms` footer.
`--quiet` suppresses the success line, `--verbose` adds per-phase
timings (include / parse / codegen). Exit codes per cli.md §3.9
+ §5: `0` clean, `4` on any diagnostic, `1` on host IO, `2` on
usage. `.gr` sources route to a "not yet implemented" stub until
v0.3 wires the gero-lang front-end.

A `zig build check-examples` step drives every `examples/asm/*.gas`
(recursive — banks/ included) through `gero check` and is wired
into `zig build ci` alongside the existing `test-examples`.
