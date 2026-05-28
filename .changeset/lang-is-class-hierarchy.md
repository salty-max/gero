---
bump: minor
---

`is` now accepts a class name on the RHS for runtime class-type
checks via the vtable pointer:

```
def report(a: Animal)
  if a is Dog
    print "found a Dog"
  end
end
```

Receiver must be a class-typed value (or `&Class` reference —
auto-dereffed per §3.4.4). Lowers to a single vtable-pointer
compare against the target class's compile-time-known vtable
address (3-4 instructions, patched after `emitVtables` runs).

Statically-decidable shapes emit `W_DEAD_TEST` (receiver's
exact type / an ancestor matches → always true; target unrelated
to the receiver's hierarchy → always false). Struct receivers
reject with `E_TYPE_IS_NON_DYNAMIC` — structs have no runtime
type identity.

Also adds class-subtype assignability so `report(Dog())` /
`let a: Animal = Dog()` work. Without this, every typed binding
was its exact class and `is` had no runtime case to fire on.

The `is X as binding` shape for guarded downcast is deferred to
a follow-up — the bare bool form is the minimum viable starting
point.

Closes #294.
