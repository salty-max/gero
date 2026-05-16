---
bump: patch
---

Wire the `char_lit` AST variant through the lang front-end. Before
this change, `'A'` parsed as `Expr.int_lit{value=65}` — char-ness
was lost in the AST, and the `Expr.char_lit` / `Pattern.char_lit`
variants were dead code.

**What changed**

- `expr.zig` / `pattern.zig` parsers inspect `source[tok.start]`
  on `int_lit` tokens; when it's `'`, the parser emits a `char_lit`
  variant instead. The lexer's existing `int_lit` normalization
  (carrying the byte value) is preserved.
- `typecheck.zig` types `char_lit` as the `char` primitive
  (previously typed as `u8`). Per spec §3.1, `char` is a distinct
  primitive from `u8` with a no-op cast between them.

**User-visible behavior**

- `let c = 'A'` now infers `c: char` (was `c: u8`).
- `let c: u8 = 'A'` now errors with `E_TYPE_MISMATCH` (was
  accepted via the prior u8 typing). Use `'A' as u8` to opt in.
- `let c: char = 'A'` accepts.
- Pattern matching on `case 'A' =>` now produces a `char_lit`
  pattern node (was `int_lit`). No user-visible difference at
  match time.
