---
bump: patch
---

Fix `&T` references to value-type aggregates (`struct` / `[T; N]` /
`Vec(T)` / tuple). Such a reference was passed **by value** — the
argument was copied onto the stack while the parameter slot held only a
2-byte pointer — so mutation through the reference never reached the
caller and field / index / method access was mis-based (it read the
pointer's own bytes). `&class` was unaffected (a class instance is
already a heap pointer).

Two coordinated changes restore the §3.4.4 contract (a `&T` is a 2-byte
pointer; mutation through it is visible to the caller; it auto-derefs at
field access, indexing, and method calls):

- A reference-typed argument is pushed as the pointer, never copied by
  value — in both free-function calls and method dispatch.
- A reference-typed aggregate binding dereferences once at access time
  (loading the pointer value as the base), mirroring what class
  receivers already did.

Now `def bump(p: &P) p.x = p.x + 1 end`, `a[i] = v` through a
`&[T; N]`, and `v.push(x)` through a `&Vec(T)` all mutate the caller's
value. Passing a struct / tuple **by value** still copies (unchanged).
