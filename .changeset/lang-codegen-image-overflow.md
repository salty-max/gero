---
bump: patch
---

A program too large to compile now reports a clean diagnostic instead of
panicking the compiler. Three pathological-size narrowings were hardened:

- **Image overflow** — when the image (code + interned string pool +
  data) outgrows the addressable 16-bit space, the offset → address
  conversions clamp at the ceiling during emission (so codegen completes)
  and a post-emit size check against `0xFE40` reports the new
  `E_CODEGEN_IMAGE_OVERFLOW`.
- **Frame / parameter overflow** — a function (or lambda) whose static
  frame estimate exceeds `u16`, or whose parameter list overruns the
  `i16` offset range, no longer panics on the prologue's narrowing cast;
  the over-127-byte frame is reported as `E_CODEGEN_FRAME_TOO_LARGE` as
  the body emits.
- **Bank overflow** — a `@bank` def whose code exceeds the 16 KiB bank
  window is now rejected with `E_CODEGEN_BANK_OVERFLOW` rather than
  silently truncated to a faulting image.
