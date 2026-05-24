---
bump: minor
---

The typechecker now emits `E_CAST_PRECISION_LOSS` (warning) at
every "store into a typed slot" site when the source's range
doesn't fit in the destination's — let-init, assignment, call
args, returns, struct + class literal fields, variadic args,
and method-call args. Adding an explicit `as T` cast suppresses
the warning. Closes #256.

Widening conversions are now implicit per spec §3.5.1
conversion table — `u8 → i16`, `i8 → i16`, `u8 → u16` no
longer require `as`. Sign-flips at equal width (`i16 → u16`,
`u8 → i8`, etc.) keep losing half the range, so they warn.
`char` is treated as `u8`-equivalent for both rules (no-op
per spec §2.5).

`gero check` exits `0` on warning-only programs; `--werror`
escalates per the previous PR. Drops the duplicate
`E_TYPE_NARROWING` from §5.2 / the registry — `E_CAST_PRECISION_LOSS`
is the canonical code.
