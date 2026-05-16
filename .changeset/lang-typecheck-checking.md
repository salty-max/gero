---
bump: minor
---

Third slice of the gero-lang typechecker. Adds operator / call / cast
/ assignment type checking and bidirectional integer-literal inference
on top of the resolution slice.

**Bidirectional integer-literal inference**

`inferExpr` now takes an optional `hint` parameter. When the hint is
an integer primitive, `int_lit` pins to the hint width instead of the
default `i16` and the literal is range-checked against the target:

- `let x: u8 = 0` — accepts (pins to `u8`).
- `let x: u8 = 256` — emits `E_TYPE_MISMATCH` ("literal 256 does not
  fit in `u8`").
- `let buf: [u8; 64] = [0; 64]` — the array-repeat propagates the
  element hint down to the value.

The hint flows through `let` / `const` annotations, `return` against
the enclosing fn ret type, assignment RHS against the LHS type, and
call args against each declared param type.

**Operator type rules (§4.2.1)**

- Arithmetic (`+ - * / %`): operand types must match, must be numeric
  (`i8` / `u8` / `i16` / `u16` / `fixed`); result = same type.
  `str + str` is a special case that returns `str`.
- Comparison (`== != < <= > >=`): operand types must match; result
  is always `bool`.
- Logical (`and` / `or` / `not`): operands must be `bool`; result is
  `bool`.
- Bitwise (`& | ^`): operand types must match and must be integer;
  result = same type.
- Shift (`<< >>`): LHS and RHS must both be integer (any width);
  result = LHS type.
- Unary `-x`: operand must be numeric; result = same type.
- Unary `not x`: operand must be `bool`; result = `bool`.
- Unary `~x`: operand must be integer; result = same type.

Operator failures emit `E_TYPE_MISMATCH` with a message naming the
operator and the rejecting type.

**Cast `as T` validation (§3.5.1)**

Casts route through a single `canCast(from, to)` table covering
integer ↔ integer (any width / sign), `bool` ↔ integer, `fixed` ↔
integer, `u8` ↔ `char`, and same-primitive identity. Everything else
(class casts, function-pointer reinterpret, reference casts) emits
`E_CAST_INVALID`.

**Function call**

- Callee must resolve to a `function` type — otherwise
  `E_TYPE_MISMATCH` ("called value has type X, expected a function").
- Arg count must equal param count — otherwise `E_TYPE_ARG_COUNT`.
- Each arg type must match the corresponding param type (with the
  param type passed down as the hint so int-literals pin). Mismatches
  emit `E_TYPE_MISMATCH` per arg.
- Params declared without an explicit annotation skip the arg-type
  check pending the parameter-from-call-site inference slice.

**Assignment + increment**

- The LHS must be a place expression (`ident`, `field`, `index`, or
  any of those wrapped in `paren`). Otherwise `E_TYPE_MISMATCH`
  ("assignment target must be a place expression").
- RHS type must match the LHS type, with the LHS as the hint so
  compound `op=` forms infer correctly.
- `x++` / `x--` require an integer-typed place.

**Return**

`return expr` checks `expr`'s type against the enclosing fn's ret
type (passed down as a hint). Missing-ret-type fns skip the check.

**Public surface**

No new public types or functions; `gero.lang.typecheck` still returns
`CheckedProgram` with the same shape. New diagnostic codes surface in
the existing `diagnostics` slice: `E_CAST_INVALID`, `E_TYPE_ARG_COUNT`.

**Out of scope (later slices)**

- Parameter-from-call-site inference for unannotated `def` params.
- Method-call lookup (still walks receiver + args without typing).
- Field-access typing (struct / class members aren't resolved yet).
- Nullable deref, reference lifetime, match exhaustiveness,
  annotation validation, bake / varargs rules.
- Diagnostic rendering per `docs/lang-diagnostics.md`.

**Tests**

41 new tests in `tests/lang/typecheck.test.zig` (68 total) covering:
- Bidirectional `int_lit` pinning + out-of-range rejection.
- Each operator category's pass / fail paths.
- Cast table coverage + `E_CAST_INVALID`.
- Call arity + arg-type checks.
- Assignment LHS-place check + RHS type match.
- Compound `op=` and `++` / `--`.
- `return` against declared ret type.
