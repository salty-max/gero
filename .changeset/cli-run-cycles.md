---
bump: minor
---

`gero run --cycles` reports what a program cost.

The VM has always counted cycles and nothing surfaced the number for a
`.gx`. `gero bench` measures `@bench` defs in the language, which
leaves hand-written assembly — the layer where the count matters
most — with no way to answer "did that change help?".

The figure is instructions retired: the VM advances one cycle per
instruction executed, with no per-opcode cost model, so a `div` counts
the same as a `mov`. An `int` serviced by the host is the host's work
and is not counted. Execution is deterministic, so the number is a
property of the program rather than of the machine it ran on, and two
runs are directly comparable — which is the whole point of having it.
