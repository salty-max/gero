---
bump: minor
---

Codegen for class inheritance — `extends`, vtable override,
`super.method`, `super.field` with shadowing. Closes #260.

**Layout** — single inheritance:

- Child instance layout = parent's instance layout (inherited
  field offsets preserved) + child's own fields appended at the
  tail. Shadowing creates a separate slot — the parent's field
  stays addressable via `super.field` while the child's
  `self.field` resolves to the new appended slot.
- Child vtable = parent's vtable copied; overrides reuse the
  parent's slot index; brand-new methods append at fresh slots.
  Vtable emit walks `method_order` per class so the bytes land
  in slot order.
- Layouts are computed in a separate `computeLayouts` pass
  (memoized + chain-recursive on `extends`) so a child whose
  parent isn't yet laid out resolves the parent first.

**Constructor** — `Child()` walks the method-owner chain to find
the closest `init` definition (own or inherited) and direct-calls
that class's mangled label. A child with no own init but a
parent that defines one gets the parent's init for free.

**`super.method(args)`** — bypasses the vtable. The codegen
finds the closest ancestor that owns the method (walking
`parent_name` from the enclosing method's class) and emits a
direct call to `Ancestor.method`. Self is loaded from `fp+4`
(the current method's implicit param).

**`super.field`** — loads `self`, then word/byte-loads at the
parent-side field offset (walking the parent chain to find the
slot the parent's own `self.field` would use). The shadowed
parent slot stays in instance memory exactly because the
inherited layout never recycled it.

**Out of scope** (M3b finishing touches after closures):

- `@final` devirtualization
- `@abstract` faulting stubs
- `@static` (class-level methods with no `self`)
- `@private` codegen enforcement (typechecker concern)

Eight new codegen tests cover inherited method (no override),
child override via vtable, `super.method` bypass, inherited
fields, shadowed field + `super.field`, child-without-init
reuses parent's init, three-level chain, and dynamic vtable
dispatch on shared slots.
