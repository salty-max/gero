---
bump: minor
---

A program that gives up now raises a fault instead of halting like it
finished. `panic`, `unreachable`, `todo`, `assert`, and a failed
`test.assert_*` all printed a message and emitted `hlt` — the same
instruction a clean exit uses — so nothing downstream could tell a
crashed program from a successful one. `gero run` returned `0` for a
program that panicked.

They now end in `sys trap` (`0x30`), raising the new **trap** fault
(vector `0x06`). With no handler installed the VM stops with
`halted_on_fault`, so `gero run` exits `6` and reports which fault
fired. A program can still install a handler on vector `0x06` to
catch its own traps.

The VM also records the vector of the most recent fault, so a host
can say *which* fault stopped a program rather than only that one
did — `StepResult.halted_on_fault` carries no vector of its own.
`gero run`'s message names it:

```
gero run: unhandled fault at ip=0x1110 — trap (panic / failed assertion)
```

**Breaking for hosts:** a program whose failure path runs `panic` or a
failed assertion now reports a fault where it previously reported a
clean halt, and `gero run` exits `6` rather than `0`.
