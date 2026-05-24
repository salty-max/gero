---
bump: minor
---

`assert(cond, msg?)` and `debug_assert(cond, msg?)` are now
always-in-scope builtins per spec §5.3. Both validate the cond
against `bool` and the optional msg against `str` at the
typechecker, and reject 0-arg / 3+arg shapes with
`E_ASSERT_ARG_COUNT`. On `false` the emitted sequence prints the
message via `sys print_str` (when provided) and halts the VM —
the host sees the diagnostic before the clean halt. `assert`
fires in every build mode; `debug_assert` is elided to zero
bytecode (args not evaluated) under
`--optimize=release` / `=size`, with a
`W_DEBUG_ASSERT_SIDE_EFFECT` warning when a `debug_assert` arg
contains a call, since the call disappears in release. Adds
`CompileOptions.optimize` (`debug` / `release` / `size`) plumbed
through to the codegen — same enum the CLI's `--optimize` parses.
Closes #219.
