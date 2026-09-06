---
bump: minor
---

The assembler can emit `sys`. It resolved `int` (`0xFC`) but not `sys`
(`0xFB`), so hand-written asm could not reach the syscall surface ISA
§5.13.1 defines — printing, the `format_*_to_buf` family, `alloc`, and
`trap` were all unreachable. A `.gr` program printed a number with
`print x`; the equivalent asm had to convert digits by hand.

§5.13 calls `sys` the embedding boundary, and the assembler could not
cross it. `asm.md` §2.3 now documents both host-call mnemonics and what
separates them.
