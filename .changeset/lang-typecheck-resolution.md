---
bump: minor
---

Second slice of the gero-lang typechecker (#235). Adds two-pass
symbol resolution and basic-form type inference on top of the
slice-1 scaffolding.

**Pass 1 — top-level decl registration**

Every module-scope `let` / `const` / `def` / `class` / `struct` /
`enum` / `use` lands in the module scope before the walker runs, so
forward references across the file resolve cleanly.

**Pass 2 — resolution + inference**

- `TypeAnn.named` resolves to either a primitive (when the lexeme
  hits the `i8`/`u8`/`i16`/`u16`/`int`/`uint`/`bool`/`nil`/`str`/
  `fixed`/`char` table) or to a user-defined declaration in scope.
  Misses emit `E_TYPE_UNDEFINED`.
- `Expr.ident` looks up the name in scope. Misses emit
  `E_UNDEFINED_SYMBOL`.
- `let x = expr` infers `x`'s type from the initializer's expression
  type. Literals pin to their canonical primitive (`int_lit → i16`,
  `fixed_lit → fixed`, `bool_lit → bool`, `nil_lit → nil`,
  `char_lit → u8`, `str_lit → str`).
- `let x: T = expr` resolves `T`, infers the init's type, and emits
  `E_TYPE_MISMATCH` when they don't structurally match.
- `def fn(a: T1, b: T2) -> R` registers `fn: fn(T1, T2) -> R` in
  module scope and `a: T1`, `b: T2` in the function scope.
- Recursive `def fn(n)` that references itself in its body without
  an explicit `-> R` annotation emits `E_TYPE_RECURSIVE_NO_RET`
  (per spec §3.5).
- `class` declarations open a class scope; fields + methods are
  registered for resolution. Method bodies open their own fn scope.
- Lambda params are registered in the lambda's body scope.
- `match`, `if let`, `while let`, `for-in` arm/loop bindings
  register in their respective scopes.
- Duplicate names in the same scope emit `E_TYPE_REDEFINED`.

**Public surface**

`gero.lang.typecheck` now produces meaningful diagnostics. Codes:
`E_TYPE_REDEFINED`, `E_TYPE_UNDEFINED`, `E_UNDEFINED_SYMBOL`,
`E_TYPE_MISMATCH`, `E_TYPE_RECURSIVE_NO_RET`.

`gero.lang.types` gains `primitiveFromName(name) -> ?Primitive` and
`render(allocator, type) -> []const u8` (human-readable form for
diagnostics).

**Out of scope (later slices)**

- Bidirectional inference for integer literals (today `int_lit`
  always pins to `i16`, so `let x: u8 = 0` errors until slice 3).
- Operator / binary / unary / call / method-call result types.
- Nullable deref discipline, reference lifetime, match
  exhaustiveness, annotation validation, bake / cast / varargs
  rules — slices 3-7.
- Diagnostic rendering per `docs/lang-diagnostics.md` — slice 8.

**Tests**

27 tests across `tests/lang/typecheck.test.zig` covering:
- Scaffolding walker smoke (every AST surface)
- Literal-type inference per primitive
- Ident resolution + forward references
- Named-type resolution (primitives, aliases, user types, misses)
- Redefinition error + cross-scope shadowing
- Function-signature registration + recursive-return check
- Whole-module + selective imports
