---
bump: minor
---

feat(wasm): breakpoints via the ISA's `brk` opcode

Setting a breakpoint patches `brk` over the byte at an address and
stores the original. `vm.step` already reports `.breakpoint`, so the
run loop needs no per-instruction address check — a breakpoint costs
nothing when it is not hit, which is what lets the fastest speed
setting actually be fast.

Three things make it behave the way a user expects rather than the way
the mechanism does:

- `gero_vm_peek` returns the displaced byte, so a memory pane or
  disassembly shows the program rather than the instrumentation.
  Otherwise setting a breakpoint visibly rewrites the code on screen.
- Stopping reports the address that was set. `brk` is one byte and
  `step` advances past it, so `ip` is rewound to where the user
  clicked.
- Resuming lifts the patch for exactly one instruction, then replaces
  it. Without that, resuming traps on the same breakpoint forever.

Breakpoints belong to the image they were set in, so `load` and `reset`
clear them.
