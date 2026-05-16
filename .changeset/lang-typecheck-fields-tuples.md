---
bump: minor
---

Sixth slice of the gero-lang typechecker. Adds field / method
resolution for structs and classes (§3.4.2, §6) and
tuple-destructuring + bail-pattern flow analysis for multi-return
fallible calls (§3.4.1).

**Field / method resolution**

Two new registries on the `Checker` mirror `enum_registry`:

- `struct_registry: StringHashMap(*const StructDecl)`
- `class_registry: StringHashMap(*const ClassDecl)`

Populated by the pre-pass over `program.statements`. Consumers:

- `inferExpr.field` — resolves `obj.field` against the receiver's
  named struct or class decl. Walks the class inheritance chain.
  Missing field → `E_TYPE_UNDEFINED_FIELD`.
- `inferExpr.method_call` — resolves `obj.method(args)` against
  the class's `methods` slice (inheritance-aware). Missing →
  `E_TYPE_UNDEFINED_METHOD`. Arg-count + per-arg type check fires
  against the method signature, skipping the implicit `self` slot.
- `inferExpr.struct_lit` — validates against the registered decl:
  unknown fields → `E_TYPE_UNDEFINED_FIELD`; missing required
  fields on `struct` decls → `E_TYPE_MISSING_FIELD`; per-field
  value-vs-declared-type check via the new `assignable`
  predicate. Class literals don't require every field (constructors
  fill defaults).
- `inferExpr.self_expr` / `super_expr` — inside a class method
  walked via `checkDefDecl`, `self` resolves to `Named(ClassName)`
  and `super` resolves to `Named(ParentName)`. Enables typed
  `self.field` / `super.method()` chains.

**Multi-return tuple flow (§3.4.1)**

- `let (a, b, …) = call()` — when the init's type is a `tuple(...)`,
  each ident element is typed from its slot. Arity mismatch emits
  `E_TYPE_TUPLE_ARITY`.
- Two-element shape `let (value, err) = …` where the err slot is
  `T?` registers a sibling correlation. When the surrounding code
  uses the canonical bail pattern `if err != nil return end`, the
  fall-through gain promotes the value slot to the `non_nil` set,
  so subsequent `value.method()` calls don't fire
  `E_NULL_DEREF`.
- `detectNilBailGain` now recognizes both bail forms:
  - `if x == nil return end` — `x` is non-nil after.
  - `if x != nil return end` — sibling slot is non-nil after.

**`assignable` predicate**

A new module-level `assignable(actual, expected)` predicate widens
the previous strict `Type.eql` check at four call sites: let-init,
const-init, assignment, return, call arg, method arg, and struct /
class literal fields. The widening:

- `T → T?` (non-nil to nullable) is accepted.
- `nil → T?` is accepted.
- Tuples assign per-slot via the same predicate.

Operator-equality checks (arith, bitwise, comparison) stay strict —
mixing `u8` and `i16` in `+` should still error.

**Bidirectional `tuple_lit` inference**

`(0, nil)` against a `(i16, str?)` hint now pins each slot. Without
this, `nil` would default to `nil_` and the tuple return would
mismatch.

**Public surface**

No new public types or functions; `gero.lang.typecheck` still
returns `CheckedProgram` with the same shape. New diagnostic codes
surface in the existing `diagnostics` slice:
`E_TYPE_UNDEFINED_FIELD`, `E_TYPE_UNDEFINED_METHOD`,
`E_TYPE_MISSING_FIELD`, `E_TYPE_TUPLE_ARITY`.

The `docs/lang-diagnostics.md` table + registry are updated to
list the four new codes.

**Out of scope (later slices)**

- Annotation validation (`E_ANN_*`) — slice 7.
- Bake / cast-range / varargs rules — slice 7.
- Rendered-diagnostic shape per `docs/lang-diagnostics.md` —
  slice 8.

**Tests**

15 new tests in `tests/lang/typecheck.test.zig` (116 total)
covering:
- Struct field access + literal field validation (unknown / missing
  / mismatch).
- Class field access + method-call resolution (unknown method,
  arg-count mismatch, inherited fields).
- `self.field` typing inside method bodies.
- Tuple destructuring with typed init + arity mismatch.
- Multi-return bail propagating non-nil to the sibling slot.
