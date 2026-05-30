---
bump: minor
---

`==` / `!=` now work on struct values, and `str` equality is
content-based.

**Structs** compare structurally per §3.4 ("structurally equal if
fields equal"): each field compares with the semantics its own `==`
uses — scalars / `&T` / class / payload-free enum by value or pointer
identity, `str` by content, nested structs recursively. A struct with
no `str` field reduces to a fast byte compare over its packed width;
a struct with a `str` field uses per-field dispatch so those fields
compare by content. Both operands are materialized as by-value stack
copies, so two struct-returning calls (which share the sret scratch)
and struct-literal operands compare correctly. The result is a `0`/`1`
boolean usable as a value (`let eq = a == b`) and in a fused condition
(`if a == b`). Ordering operators (`<`, `<=`, `>`, `>=`) remain a
codegen error on structs — only equality is defined.

**Strings:** `str == other` / `!=` now compare **content**
(lexicographic, byte-wise) per §3.2.1 instead of pointer identity, so
two equal strings built at runtime (interpolation, etc.) in distinct
buffers compare equal. This also fixes scalar `str ==`, not just
str-typed struct fields.

Closes #322.
