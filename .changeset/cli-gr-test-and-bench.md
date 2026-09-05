---
bump: minor
---

`gero test` runs `@test` defs in `.gr` modules alongside the existing
`.gas` golden programs — one walk of `[test].include` covers both.
Each module is parsed and type-checked once, then lowered once per
`@test` def with that def as the entry point. A clean `hlt` passes;
the `trap` fault a failed `test.assert_*` or `panic` raises fails, as
does any other fault or a cycle-budget overrun. `[pattern]` filters
by def name. Exit stays `7` when any test fails.

`gero bench` ships. It discovers `@bench` defs through the same walk,
runs each `--iter=N` times (default 1000) on a fresh VM per
iteration, and reports avg / min / max cycle counts from the VM's own
counter:

```
running 2 benchmarks, 1000 iterations each
bench sum_to_ten ... ok  (avg 162 cyc, min 162 cyc, max 162 cyc)
```

The VM is deterministic, so identical min and max is the expected
shape — a spread means the benchmark body itself varies.

With `bench` wired, every subcommand `gero --help` lists is
implemented, and the "not yet implemented" fallbacks in the dispatcher
and the help renderer are gone.

`cli.md` §3.5 documented an output format and exit codes predating the
implementation; its exit line also contradicted §5, which calls itself
the single source of truth. A faulting bench is a runtime fault (`6`),
and no benches matched is not an error. §3.4 now describes both halves
of the test walk rather than saying the lang-level form "lands with
the future gero-lang compiler".
