---
bump: minor
---

feat(wasm): VM sessions, stepping, and the print buffer

`gero.wasm` can now run what it compiles. Several sessions coexist,
each with its own machine, memory, and output; a handle held past
`destroy` is refused rather than addressing whoever takes the slot
next.

`step` distinguishes why it stopped — budget, `hlt`, `brk`, or a fault
with its vector — because a host's run loop branches on all four.

The print buffer is bounded and never fails the program. The VM raises
invalid-opcode when its writer errors, so a sink that failed on
overflow would turn a chatty program into a crashing one; output past
the buffer is dropped and counted instead, and the count reaches the
host so a flood is visible rather than silent.

A `.gx` that will not load explains why in the same words `gero run`
uses — `load_error` moves into the library so a terminal, an editor,
and the playground cannot describe the same broken file differently.
