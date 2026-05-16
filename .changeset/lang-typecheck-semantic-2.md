---
bump: minor
---

Fifth slice of the gero-lang typechecker. Adds match-arm
exhaustiveness checking against `enum` declarations (§4.8) and the
stack-lifetime check for `return &local` (§3.4.4).

Multi-return tuple flow analysis was originally part of this slice
but is deferred to slice 6 — its end-user value lives in code
shapes that also need field-typed diagnostics, so the two land
together.

**Match exhaustiveness (§4.8)**

- A new `enum_registry: StringHashMap(*const ast.EnumDecl)` lives
  on the `Checker` and is populated by a pre-pass over
  `program.statements` (stable slice-element pointers).
- `match expr` whose scrutinee resolves to a `Named(EnumName)`
  type registered in the map gets exhaustiveness-checked:
  - Each arm's pattern is walked. `variant_pattern` contributes its
    variant tail to a "covered" set. `or_pattern` walks each
    alternative. `wildcard` and bare `ident` (binding catch-all)
    mark every remaining variant as covered.
  - After all arms, missing variants emit `E_MATCH_NON_EXHAUSTIVE`
    naming the first three (with `…` when more remain).
  - An arm that covers a variant already handled emits
    `E_MATCH_UNREACHABLE_ARM`. Any arm following a wildcard does
    the same.
- Match on a non-enum scrutinee (int / str / tuple / `Vec`)
  silently skips the exhaustiveness check.

**Reference stack lifetime (§3.4.4)**

- A new `fn_locals: ?StringHashMap` lives on the `Checker`. On
  `checkDefDecl` entry it's saved and replaced with a fresh empty
  set; on exit it's restored. Nested `def`s push their own frame
  so an inner fn doesn't inherit outer-fn locals.
- `registerName` adds the registered name to `fn_locals` when the
  set is non-null (i.e. inside a fn body). Params land in the set
  the same as nested `let`s.
- `checkReturn` matches the lexical shape `return &ident` against
  `fn_locals` — when the ident is a fn-local, it emits
  `E_REF_STACK_LIFETIME`. Module-level / static bindings pass.

Cross-call lifetime tracking (a ref stored in a class field that
outlives the referent) stays out of scope per spec.

**Public surface**

No new public types or functions; `gero.lang.typecheck` still
returns `CheckedProgram` with the same shape. New diagnostic codes
surface in the existing `diagnostics` slice:
`E_MATCH_NON_EXHAUSTIVE`, `E_MATCH_UNREACHABLE_ARM`,
`E_REF_STACK_LIFETIME`.

**Out of scope (later slices)**

- Multi-return tuple flow analysis — slice 6.
- Field-resolution typing for `obj.field` / `super.field` —
  slice 6.
- Annotation validation — slice 6.
- Bake / cast-range / varargs rules — slice 7.
- Rendered-diagnostic shape per `docs/lang-diagnostics.md` —
  slice 8.

**Tests**

11 new tests in `tests/lang/typecheck.test.zig` (101 total)
covering:
- Exhaustive enum match accept / reject paths.
- Wildcard / bare-ident catch-all coverage.
- Duplicate-variant + arm-after-wildcard unreachability.
- Or-pattern alternative coverage.
- Non-enum scrutinee skip.
- `return &local` / `return &param` / `return &module_static`.
