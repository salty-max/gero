---
bump: patch
---

gtx-16's vblank IRQ moves from vector `0x06` to `0x07`. `0x06` is the
ISA's program-initiated trap — the vector `sys trap` raises after a
failed `test.assert_*`, `panic`, `unreachable` or `todo` — so a cart's
frame boundary and a deliberate give-up fired the same handler, and a
cart installing a vblank ISR silently swallowed its own traps.

The ISA's reserved-vector row is corrected with it: it read
`0x06..0x1F`, overlapping the trap entry listed directly above it.

A cart or handler written against the old spelling should move to
`@interrupt $07`.
