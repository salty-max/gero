---
bump: patch
---

Cross-bank calls (`@bank N`) now pass parameters and return values
correctly. The trampoline is frame-transparent: the callee reads its
arguments at the same frame offsets as a direct call, so banked
functions that take parameters — and that return structs / tuples —
work instead of reading six bytes of stale stack.

Nested cross-bank calls unwind correctly. Each level parks its (bank,
return-address) on a small save-stack in low RAM, so a banked function
calling another banked function restores the caller's bank on return.

Cross-bank calls are interrupt-safe. The trampoline masks interrupts
around its save-stack critical sections and both enters and returns via
`rti`, which restores the saved interrupt state and jumps atomically —
so the target and return-address ride the stack rather than a register
across any unmask, and an `@interrupt` handler that itself cross-bank-
calls can neither corrupt the shared save-stack nor an in-flight call.

Banked programs now run their stack in low RAM instead of leaving it at
the boot `sp` (`0xFFFE`). The boot stack grows down through the IO page
and the bank window (`0xC000..0xFEFF`), which is bank-switched for a
banked program — so call frames would corrupt across a bank hop. Both
`sp` and `fp` move (the entry's own locals are `fp`-relative). Unbanked
programs keep the boot `sp` and are unchanged.

`@interrupt` handlers are now transparent to the interrupted code.
Interrupt entry preserves only `ip`/`fp`/`flg`, so the compiler saves +
restores the general-purpose registers around the handler body and
gives the handler its own stack frame. Previously a handler clobbered
the interrupted code's live registers, and a handler with locals
aliased the interrupted frame and misaligned its `rti`.
