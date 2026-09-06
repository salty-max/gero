---
bump: minor
---

`VM.snapshot` and `VM.restore` capture and reload execution state.

An embedder that wanted save-states, rewind, or to run two programs
alternately had to reach into `VM`'s fields and get the copy semantics
right. `VM` mixes state that copies by value (registers, RAM) with an
allocator-backed bank pool that needs a deep copy, and with a device
registry holding pointers to live host objects that must not be copied
at all — a naive struct copy shares the banks and the peripherals, and
either `deinit` frees what both point at.

A snapshot captures registers, RAM, banks and the scalar bookkeeping. It
deliberately does not capture the mapped devices or the host hooks:
those stay live across a restore, so a peripheral written before a
snapshot is still mapped and still the same object afterwards. Only what
the program can change comes back.

Restoring a banked snapshot into a VM with a different bank shape
reports `error.BankShapeMismatch` rather than corrupting either.
