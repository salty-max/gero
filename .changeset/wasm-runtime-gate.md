---
bump: patch
---

test: a wasm runtime gate over the example corpus

`wasm32` was only ever compile-checked. The cross-target matrix proves
the library builds for it; every runtime test gero has runs natively,
so nothing proved it *behaves* there.

`zig build test-wasm-examples` now builds and runs every program in
`examples/` through `gero.wasm` and diffs stdout against the same
`.expected` files the native gates use — so a difference is a genuine
native-vs-wasm divergence rather than a fixture mismatch. It runs in
`verify`, in `ci`, and on pull requests.

It found one on its first run. `int $10` and `int $21` are host
conventions the CLI implemented inline, so every assembly example
faulted under wasm on an unhandled vector. Those conventions now live
in `gero.vm.host_int`, shared by both hosts — a program that prints in
a terminal prints in a browser.

The artifact also carries the sample corpus, so the application
consumes it rather than keeping a copy that drifts.
