---
bump: minor
---

Codegen for single-class OOP — instance allocation, vtable
emission, constructor lowering, field read/write, and method
dispatch via vtable.

**Scope:**

- `let p = Player()` constructor: bump-allocates the instance
  (`sys alloc` from the heap allocator shipped in the prior
  PR), writes the class's vtable pointer at instance offset 0,
  invokes `init(self, args...)` when declared, returns the
  instance address in `acu`.
- Instance layout per spec §6: 2-byte vtable pointer at offset
  0, then field bytes contiguous (1 byte per u8 / i8 / bool /
  char, 2 bytes per i16 / u16 / fixed / reference / named
  field).
- Vtables live in the base image — appended after the code body
  and the string pool, one u16 entry per method in declaration
  order. Constructor-side vtable address slots are recorded as
  patches and resolved after the vtable emission pass.
- `obj.field` and `self.field` read + write — word load /
  store via `mov [base + ofs], dst` for fields with i8-fit
  offsets, synthesized `add` + indirect for larger offsets.
- `obj.method(args)` and `self.method(args)` dispatch through
  the vtable — load vtable_ptr from instance[0], load method
  address from `[vtable + slot * 2]`, push self + user args
  right-to-left, `call_reg`.
- `self` expression — bound as the first method parameter at
  fp+4; existing free-fn calling convention applies unchanged.

**Out of scope (M3b chunk 2 / closures):**

- Inheritance (`extends`), vtable copy-and-override,
  `super.method`, `super.field` shadowing.
- `@final` devirtualization, `@abstract` faulting stubs,
  `@static` (class-level methods with no `self`).
- `@private` enforcement at codegen (typechecker concern via
  annotation validation).
- Closures and capture analysis.
