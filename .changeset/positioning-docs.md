---
bump: patch
---

Two documents that say what gero-lang is for and why the assembler did
not go away when it arrived.

`docs/asm-vs-lang.md` positions the three layers — bytecode as the
artifact, asm as the machine's own language, gero-lang as the
application one — and settles which to reach for, with the same
routine written both ways. The numbers in it are measured on this
build, not estimated: summing 1..100 and printing the result costs
**509 cycles in asm and 1520 in gero-lang**, and the routine is **20
bytes against 95**.

The whole-image figure is the one that misleads, so it is spelled out:
a `.gr` that only prints a constant already compiles to 4617 bytes of
runtime, and the routine adds 95. gero-lang costs about 4.6 KB up
front and roughly 4× per routine — not the 147× a naive image
comparison suggests.

The README gains a "Why gero-lang?" section covering the same ground
against Lua-on-a-console, C for retro targets, and a general-purpose
language plus an engine — including what gero-lang deliberately is
not.

Both documents' code examples are checked by `zig build verify`, which
required teaching `check-doc-asm.sh` a document list; the `.gr` gate
already took one.
