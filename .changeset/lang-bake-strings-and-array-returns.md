---
bump: minor
---

`str` is now bakeable, as §3.8 has always specified ("`str` (interned
in static data)"). The bake evaluator rejected string literals
outright, so a `bake def` returning a `str` — or a struct or tuple
with a `str` field — failed to compile. A baked string's bytes are
now interned into the string pool and its pointer slot patched with
the resolved address once the pool lays out, so a baked `str` and a
runtime literal resolve identically, escapes included. Identical
bytes share one pool entry.

`$(…)` interpolation inside a bake body is rejected with a message
saying so — the evaluator has no compile-time formatter.

A `def` whose return type is a fixed array now lowers. Structs and
tuples already rode the sret convention; `[T; N]` had no return path
at all, so `def nums() -> [i16; 3]` failed with
`E_CODEGEN_UNSUPPORTED` for every element type. Because a `bake def`
is also lowered as an ordinary function, this made §3.8's `[T; N]`
bakeable claim unreachable too. Both now work.
