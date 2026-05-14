---
bump: patch
breaking: true
---

`asm.ErrorCode.reserved_opcode` (E008) removed — never emitted by
any code path, lingering placeholder for ISA additions that never
materialized.

The numeric ID `8` is intentionally left dead (no enum variant
reuses it) so any tool that parsed the asm error-code table by
number stays stable. The asm spec §8 error table loses the E008
row.

## Migration

Anyone exhaustively switching on `asm.ErrorCode` needs to drop
the `.reserved_opcode` arm. No production code in this repo had
such a match; no tests exercised it. The change is detectable
at compile time — the Zig compiler will complain if a downstream
crate matched the removed variant.

## Context

The ZP pass (`feat(vm,asm): zero-page mov forms`) filled the
previously-reserved opcode slots 0x19/0x1A/0x1B and 0x2A..0x2D.
With no reserved-but-unimplemented opcodes left in the ISA,
E008 had nothing to gate against. Removing the variant matches
the asm-complete v0.2 philosophy — no half-features, no dead
hooks.
