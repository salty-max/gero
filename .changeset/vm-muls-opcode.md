---
bump: minor
---

ISA extension: signed multiply opcodes `muls Imm16, Reg` (`0x54`)
and `muls Reg, Reg` (`0x55`) added in the previously-unused 0x5X
arithmetic block. `muls` interprets both operands as `i16`,
produces a 32-bit signed product with the low half in `dst` and
the high half in `acu`, and sets `V` / `C` when the result
doesn't fit in `i16`. Companion to existing unsigned `mul` —
needed because `mul`'s V flag false-positives on legitimate
signed products like `(-1) × 5 = -5`. Gero-lang's debug overflow
trap on `*` is the canonical consumer. Bumps `.gx` format
version `0x0002 → 0x0003` (backwards-compatible additive change
per ISA §10) and fixes the §10 doc's stale "high byte of version"
phrasing (minor is the low byte; major is the high byte).
