---
bump: major
---

`fixed` is now Q16.16 — 32-bit storage, 16 bits integer and 16 bits
fraction, range ±32767.99998 at 1/65536 precision. It was Q8.8: ±127.99.

**Breaking.** A fractional type has to span the coordinate space it is
used in, and 8.8 could not. On a 320×240 display a sprite at `x = 200`
had no representation, so positions lived in `i16` with scaling by hand
at every boundary and `x += 0.5` did not work across a screen. 16.16 is
the format PICO-8, the Genesis Sonic games and early Doom all used, for
the same reason — the previous spec cited those three as precedent for
8.8, which none of them used.

Integers are unchanged: `i16` / `u16` / `u8` remain what pixel
coordinates, tile indices and counters want, at half the storage.

What this changes for a program:

- A `fixed` occupies four bytes and two registers. Locals, globals,
  struct fields, parameters and returns all widen accordingly.
- `+` and `-` are a word each plus the carry. `*` and `/` call runtime
  helpers — four partial products for multiply, 48 restoring-division
  steps for divide. Division is the expensive operation on this
  machine; keep it out of per-frame loops.
- Dividing by zero now raises the divide-by-zero fault (vector `$03`),
  as integer division does, rather than returning a meaningless value.
- `math.fixed_sin` gains precision: it computes at quarter scale, which
  is 16× finer than the old Q8.8 result. `math.sqrt_fixed` carries 8
  fractional bits — exact for perfect squares, within ~0.3% mid-range.
- Values folded by `bake` match what the same call produces at run
  time, as before.

**ISA.** `print_fixed`, `format_fixed_to_buf` and `format_spec_to_buf`'s
`fixed` type now read the value from `acu` (low half) and `r5` (high
half) rather than `acu` alone, and a `fixed` element in `format_runtime`'s
argument array occupies two words. Hand-written asm calling those
syscalls needs updating.
