---
bump: minor
---

Complete the v0.3 lang front-end: parser-level support for every
feature the spec locks in. After this, the AST is the final shape
the typechecker can build against.

**References `&T`** (§3.4.4)

- `TypeAnn.reference` variant for `&T` in annotation position.
- `Expr.ref_of` variant for `&x` prefix in expression position.
- Same precedence as other unary prefix operators; `&Stats?` parses
  as `reference(nullable(Stats))` because postfix `?` binds inside
  the reference's inner type-ann recursion.

**`bake def` / `bake do`** (§3.8)

- `DefDecl.is_bake: bool` flag for `bake def name(...) end`.
- `DoExpr.is_bake: bool` flag for `bake do … end`.
- `kw_bake` dispatch at statement position handles both forms; at
  expression position (`const PALETTE = bake do … end`) only `bake
  do` is accepted.
- `bake` not followed by `def` or `do` surfaces a diagnostic.

**Variadic parameters `args: ...`** (§4.6.2)

- New `dot_dot_dot` token (`...`); the lexer uses longest-match so
  `..=` / `..` / `...` are unambiguous.
- `Param.variadic: bool` flag.
- Parser accepts `name: ...` as the last param of a list and breaks
  out of the param-parse loop — anything after surfaces as
  `expected )`.

**Array-repeat literals `[value; count]`** (§3.4)

- `Expr.list_repeat` variant. Parser disambiguates from
  `[a, b, c]` by the `;` after the first element.
- Empty `[]` now parses as an empty `list_lit`.
- Spec §3.4 table updated to mention the two literal forms.

**Fix**

- Pre-existing double-free in `parseParamList`'s errdefer (the
  errdefer called `freeParams` on `params.items` and then
  `params.deinit`, both freeing the same buffer). The variadic-
  rejection path was the first to actually exercise it.
