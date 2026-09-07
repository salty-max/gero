---
bump: minor
---

feat(asm): a `heap` directive, so `sys alloc` works from assembly

`sys $20` (`alloc`, ISA §5.13.1) faulted in every assembler-produced
image. The assembler wrote `heap_base = 0` and never offered a way to
set it, and ISA §7.1 says `0x0000` means no heap — so a four-instruction
program calling the documented syscall died with `heap-exhausted`.
Nothing in §5.13.1 marked `alloc` as lang-only.

`heap $ADDR` declares where the bump allocator starts, alongside `org`
in the directive list. Without it the field stays `0` and behavior is
unchanged, so assembly still owns its memory map and nothing is
reserved unasked.

The address must sit at or above the end of the emitted image, and in
a banked program below the bank window at `$C000`. Below the image the
allocator would hand out addresses over live code or data; inside the
window a bank switch would replace every allocation. `sys alloc` only
bounds the top of the heap, so neither is caught at run time — the
assembler rejects both (**E020**) and so does the loader
(`HeapInsideImage` / `HeapInBankWindow`).

ISA §7.1 states that as a constraint rather than the advice it carried
before, since a bytecode freeze locks the field's contract either way.

`gero disasm` re-emits the directive, so disassembling and
re-assembling no longer drops a program's heap.
