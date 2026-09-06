---
bump: patch
---

An `@interrupt` handler no longer leaks its bank selection into the
interrupted code.

Interrupt entry preserves only `ip` / `fp` / `flg` (ISA §6.2), and the
compiler's handler prologue saved the general registers but not `mb`. A
handler that selected a bank — `bank.switch_to`, or anything reading
banked data — returned with a different 16 KB mapped through
`0xC000..0xFEFF`, so the interrupted code resumed reading the wrong
memory. The corruption was silent and depended on where the interrupt
landed.

The cross-bank call trampoline restores `mb` itself, so a plain call
into a `@bank` def was already safe; an explicit switch was not.

`mb` is now saved and restored whenever the program declares banked
defs. An unbanked program is byte-identical — with `bank_count == 0`
the window is plain RAM and `mb` has no addressing effect.

`isa.md` §6.2 said the compiler handled this automatically. It now says
what is actually preserved, and that a hand-written handler must save
`mb` itself.
