---
bump: minor
---

Seventh slice of the gero-lang typechecker. Adds annotation
validation (§3.7), bake-context restrictions (§3.8), and variadic
call validation (§4.6.2).

**Annotation validation (§3.7)**

A static `annotation_specs` table inventories the 17 documented
annotations (memory placement, codegen control, OOP, misc) with
their target rules, arg shapes, and conflict pairs. Each decl
visitor (`checkLetDecl` / `checkConstDecl` / `checkDefDecl` /
`checkClassDecl` plus struct / enum / class-field) calls
`validateAnnotations(anns, target_bit)` which emits:

- `E_ANN_UNKNOWN` for names not in the spec table.
- `E_ANN_BAD_TARGET` when the target bit doesn't intersect the
  spec's allowed targets (e.g. `@inline` on a `let`).
- `E_ANN_BAD_ARG` when the arg shape doesn't match the rule
  (`none` / `int_lit` / `int_lit_pow2`).
- `E_ANN_CONFLICT` for pairs declared on the same decl that the
  spec marks as conflicting (`@final` ↔ `@override`,
  `@abstract` ↔ `@final`, etc.).

`E_ANN_INLINE_TOO_LARGE` and `E_ANN_CAPTURE_VIOLATION` stay
codegen / closure-analysis concerns — out of scope for this slice.

**Bake-context validation (§3.8)**

`Checker.in_bake: bool` is saved / restored around every
`checkDefDecl` body (set to `d.is_bake`). Inside the body:

- `inferExpr.ident` against a name in `mmio_names` (any module-
  level `let` annotated `@addr`) emits `E_BAKE_MMIO_ACCESS`. Both
  reads and writes catch — writes via `checkAssign` walking the
  target through `inferExpr`.
- `walkStatement.asm_stmt` emits `E_BAKE_ASM_INSIDE` when in_bake.
- `checkCall` consults `def_registry`; a call to a non-bake def
  emits `E_BAKE_FORBIDDEN_CALL`.
- `checkDefDecl` validates the bake fn's return type against
  `isBakeableType` — `Vec(T)`, references, and function types are
  runtime-only and emit `E_BAKE_NON_BAKEABLE_VALUE`.

`E_BAKE_BUDGET_EXCEEDED` stays a codegen concern (runtime
interpreter step budget) — out of scope.

**Variadic call validation (§4.6.2)**

- `checkDefDecl` calls `checkVariadicPosition`, a safety net for
  `E_VAR_NOT_LAST` (parser already enforces; the check routes any
  bypass through the documented code).
- `checkCall` detects variadic callees via `variadicCalleeDecl`
  (looks up the bare-ident callee in `def_registry` and inspects
  the last param's `variadic` flag) and routes to
  `checkVariadicCall`:
  - Leading fixed params type-check per-position.
  - Trailing args pivot on the first variadic arg's type;
    subsequent args must `assignable` to it — otherwise
    `E_VAR_HETEROGENEOUS`.
  - Wrong fixed-arity is `E_TYPE_ARG_COUNT`.

**Internal**

Two new pre-pass registries on the `Checker`:

- `def_registry: StringHashMap(*const DefDecl)` for bake-call and
  variadic-decl lookup.
- `mmio_names: StringHashMap(void)` for the `@addr`-pinned globals
  consulted in bake-context.

**Public surface**

No new public types or functions; `gero.lang.typecheck` still
returns `CheckedProgram` with the same shape. New diagnostic codes
surface in the existing `diagnostics` slice:
`E_ANN_UNKNOWN`, `E_ANN_BAD_TARGET`, `E_ANN_BAD_ARG`,
`E_ANN_CONFLICT`, `E_BAKE_ASM_INSIDE`, `E_BAKE_MMIO_ACCESS`,
`E_BAKE_FORBIDDEN_CALL`, `E_BAKE_NON_BAKEABLE_VALUE`,
`E_VAR_NOT_LAST`, `E_VAR_HETEROGENEOUS`.

All ten codes were already listed in `docs/lang-diagnostics.md`
(slice 8 ground them in); no doc updates required.

**Out of scope (later slices)**

- `E_CAST_PRECISION_LOSS` narrowing warning — follow-up.
- `E_ANN_INLINE_TOO_LARGE` (bytecode-size) — codegen.
- `E_ANN_CAPTURE_VIOLATION` (closure mutation) — closure analysis
  slice when that lands.
- `E_BAKE_BUDGET_EXCEEDED` — codegen.
- Rendered diagnostic shape per `docs/lang-diagnostics.md` —
  slice 8.

**Tests**

19 new tests in `tests/lang/typecheck.test.zig` (146 total)
covering:
- All four annotation codes (unknown / bad target / bad arg /
  conflict) plus accept paths for `@bank N`, `@addr + @volatile`,
  `@align(16)`.
- All four bake codes (asm / MMIO / forbidden-call / non-bakeable
  return) plus accept paths for simple bake and bake-to-bake calls.
- Variadic homogeneous accept, heterogeneous reject, fixed-prefix
  + variadic.
