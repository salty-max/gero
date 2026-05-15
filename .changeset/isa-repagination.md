---
bump: minor
breaking: true
---

ISA repagination: one 16-slot page per role. All opcode bytes outside the `mov`,
stack, and primary-arithmetic families are renumbered — logical/bitwise moves to
`0x6X`, shifts/rotates to `0x7X` (with `asr` reunited with its siblings), `cmp`/`tst`
to `0x8X`, branches to `0x9X`, subroutines to `0xAX`, flags to `0xBX`, misc to `0xCX`.
`adc`/`sbc` get a dedicated `0x5X` carry-arithmetic page; `sext` rejoins arithmetic
at `0x4F`. `Operand` gains `reg_indirect` and `indexed` so the VM schema matches
the resolver's kind enum — disassembly stops special-casing by opcode byte.
