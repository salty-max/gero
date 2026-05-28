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

Guarded downcast — `is ClassName as <ident>` — binds the
receiver under the new name inside the surrounding `if` arm,
typed as the target class:

```
def report(a: Animal)
  if a is Dog as d
    d.bark()           -- d: Dog in this arm
  end
end
```

Casing convention disambiguates from the regular cast operator:
lowercase post-`as` ident → binding; uppercase → `as T` cast.

Closes #294.
