---
bump: minor
---

`str` values gained their instance members (§3.2.1): `s.len` (the byte
count to the null terminator, a `u16` property), `s.at(i)` (the byte at
index `i`, a `u8`, debug-bounds-trapped), and `s.cmp(other)` (byte-wise
lexicographic ordering, an `i16` — `< 0` / `0` / `> 0`). They lower to
the existing byte-walk primitives — no new syscall.

These were previously untyped: a `str` field / method access silently
resolved to no type (a strong-typing hole) and then failed in codegen.
Now they carry concrete types, and an unknown `str` member is a clean
`E_TYPE_UNDEFINED_FIELD` / `E_TYPE_UNDEFINED_METHOD`.
