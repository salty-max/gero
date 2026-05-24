---
bump: minor
---

Plain `+` / `-` / `*` on integer types now trap on overflow in
debug builds and wrap two's-complement in release / size per
spec §4.2.1 (Rust model). Codegen emits a per-op check after the
ALU op (`jvc`/`jcc skip; int 5; skip:` — 5 extra bytes per op).
On overflow the program raises arithmetic-overflow (vector `$05`
per ISA §6); the default handler halts with a host-visible fault
marker, and programs can install a custom `int 5` handler for
diagnostic recovery. Signed `*` lowers through the new `muls`
opcode so `V` correctly reflects `i16` overflow; unsigned `*`
keeps `mul` (V = `high != 0`). Fixed-point ops remain wrap-only
per ISA §5.4.1. The `--optimize=<debug|release|size>` flag (added
by the assert builtins PR) toggles the check. Closes #218.

The spec's stale `fault vector $02` reference in §4.2.1 is also
corrected to `$05` (arithmetic overflow per ISA §6).
