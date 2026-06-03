---
bump: patch
---

Fix passing value-type aggregates (`struct` / `[T; N]` / `Vec(T)` /
tuple) across function and method call boundaries — both by reference
and by value.

**`&T` references.** A reference to a value-type aggregate was passed
*by value* (the argument copied onto the stack while the parameter slot
held only a 2-byte pointer), so mutation through the reference never
reached the caller and field / index / method access read the pointer's
own bytes. Now a reference argument is pushed as the pointer (never
copied) in both free-function calls and method dispatch, and a
reference-typed aggregate binding dereferences once at access time —
restoring the §3.4.4 contract (mutation through a `&T` is visible to the
caller; it auto-derefs at field access, indexing, and method calls).
`&class` was unaffected (a class instance is already a heap pointer).

**By value.** A `[T; N]` or `Vec(T)` parameter was sized as a 2-byte
slot and the argument pushed as an address, so the callee read garbage
instead of a copy. Both now pass by value like a struct / tuple — a
fixed array is copied (§3.4 value semantics: callee mutations stay
local), a `Vec` moves its 6-byte header (§3.4.3). This covers array /
Vec literal arguments, arguments alongside scalars / other aggregates /
references, and method arguments.
