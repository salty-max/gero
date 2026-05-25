---
bump: minor
---

The `bake` compile-time evaluator per spec §3.8 is now live.
`bake def name(…) -> T body end` and `bake do … end` run
against a typed-AST interpreter at compile time; results land
in the static-data segment so `const SIN_TABLE = make_sin_table()`
ships zero runtime cost. Closes #217.

The interpreter handles every shape the spec covers — integer
+ fixed-point + bool arithmetic, ident lookup + binding (`let`
/ `const` / `=`), `if` / `while` / `for-in` / `repeat … until`,
`break` / `continue` / `return`, list / array-repeat / tuple /
struct literals + indexed read + `a[i] = v` rebuild, and call
dispatch through other `bake def`s. Stdlib allowlist is empty
in this PR (`math.*` lands with #284). The instruction-budget
gate (default 100M micro-steps) fires `E_BAKE_BUDGET_EXCEEDED`
on any unbounded loop.

Codegen side: `widthOf{LetDecl,ConstDecl,TypeAnn}` widens to
`u16` so aggregate slots (`[i16; 256]` = 512 bytes) fit;
`widthOfTypeAnn` resolves `[T; N]` + `(T1, T2, …)` to actual
byte sizes. The base image grows to cover the data region only
when at least one global carries bake-init bytes — programs
without bake keep their existing tight image shape. Per-bake
serialized bytes write into `base_image[address..]` after the
code region lays out so the runtime sees the value at boot.

Typecheck: `bake def @cold` / `@inline` / `@interrupt` /
`@bank` / `@no_capture` combinations now reject with
`E_ANN_CONFLICT` per spec §3.8 (those describe runtime codegen
and have no meaning under compile-time evaluation).

Spec drift fix: `docs/gero-lang.md` §3.8 keeps the `fixed_sin`
example as the canonical design target but notes the `math.*`
follow-up — the interpreter itself is ready; only the curated
stdlib allowlist is pending.
