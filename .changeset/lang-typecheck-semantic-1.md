---
bump: minor
---

Fourth slice of the gero-lang typechecker. Adds the semantic rules
for `T?` (nullables, §3.4.1) and `&T` (references, §3.4.4), plus
basic `super` ident resolution inside class methods. Builds on the
operator / call / cast / assignment slice.

**Nullable validation (§3.4.1)**

- `T?` is rejected when `T` is not pointer-like
  (`E_NULL_NON_POINTER`). Allowed inner types: `str`, class names,
  function pointers, references. Numeric / `bool` / `fixed` / struct
  fall through to the error.
- Direct field or method access on a `T?` binding emits
  `E_NULL_DEREF` unless the surrounding flow has proven the binding
  non-nil — see flow analysis below.
- `nil` literal against a non-nullable type emits
  `E_NULL_NIL_TO_NONNULL` (with a friendlier "use `T?` for nullable
  bindings" message). `nil` against a `&T` parameter takes the
  reference-specific code instead (`E_REF_NULLABLE`).

**Flow-sensitive non-nil tracking**

A small `non_nil: StringHashMap` lives on the `Checker` and is
mutated by simple straight-line pattern matching. The forms
recognized:

- `if x != nil … end` — the then-arm body sees `x` as non-nil.
- `if nil != x … end` — symmetric to the above.
- `if x == nil … end` — the else-body sees `x` as non-nil.
- `if x == nil then return / break / continue end` — code following
  the `if` in the enclosing block sees `x` as non-nil (fall-through
  gain). Bookkeeping unwinds on block exit.

Multi-arm `elif` chains and nested checks aren't tracked yet — they
fall through to the conservative "still nullable" assumption.

`checkComparison` was relaxed so `x != nil` / `nil == p` no longer
emit a spurious `E_TYPE_MISMATCH` when one operand is the `nil`
literal — the canonical idiom now type-checks.

**Reference rules (§3.4.4)**

- `&x` where `x` is not a place expression (literal, arithmetic
  result, function-call result, etc.) emits `E_REF_TEMPORARY`.
- `&r` where `r` is already typed `&T` emits `E_REF_DOUBLE` (no
  `&&T` per spec).
- `nil` against a `&T` parameter emits `E_REF_NULLABLE`.

`E_REF_STACK_LIFETIME` (returning `&local`) stays out of scope until
the origin-tracking slice.

**`super` resolution (§6)**

`super` outside a class method, or inside a class with no `extends`
clause, emits `E_UNDEFINED_SYMBOL`. Inside a method whose enclosing
class declares `extends Parent`, `super` resolves cleanly. Type-aware
`super.field` / `super.method()` lookup lands when field-resolution
ships.

**Internal refactor**

`walkStatementSequence` replaces the flat `for (body) |s|
walkStatement(s)` loops in `checkDefDecl` / `checkFor` /
`checkMatch` so the fall-through nil gain propagates across function
bodies and loop bodies the same way it does inside `if` arms.

**Public surface**

No new public types or functions; `gero.lang.typecheck` still
returns `CheckedProgram` with the same shape. New diagnostic codes
surface in the existing `diagnostics` slice:
`E_NULL_NON_POINTER`, `E_NULL_DEREF`, `E_NULL_NIL_TO_NONNULL`,
`E_REF_TEMPORARY`, `E_REF_DOUBLE`, `E_REF_NULLABLE`.

**Out of scope (later slices)**

- `E_REF_STACK_LIFETIME` (returning `&local`) — slice 5.
- Multi-return tuple flow analysis — slice 5.
- Full field-resolution typing for `obj.field` / `super.field` —
  slice 6.
- Match exhaustiveness — slice 5.
- Annotation validation — slice 6.
- Bake / varargs rules — slice 7.
- Rendered-diagnostic shape per `docs/lang-diagnostics.md` —
  slice 8.

**Tests**

22 new tests in `tests/lang/typecheck.test.zig` (90 total) covering:
- `T?` accept / reject by inner-type pointer-likeness.
- Direct deref → `E_NULL_DEREF`.
- Flow analysis: `if x != nil` arm, `if nil != x` arm,
  `if x == nil` else, and `if x == nil then return end` fall-through.
- Method-call deref through nullable.
- `nil` against non-nullable / reference / nullable targets.
- `&local` / `&(a + b)` / `&foo()` / `&&` rules.
- `super` inside extends-class / standalone class / module scope.
