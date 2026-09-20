---
bump: patch
---

Sixty-two VM handlers documented an opcode the dispatch table does not
bind them to — every jump, every bitwise op, every subroutine
instruction and more, left behind by an opcode-map renumbering. A
reader learning the ISA from the source got the wrong byte more often
than the right one. `gero lint` now checks each handler's `/// 0xNN`
against `dispatch.zig`, so the two cannot drift again.
