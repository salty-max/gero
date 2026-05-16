---
bump: minor
---

Apply the spec-locked syntax decisions from `docs/gero-lang.md` v1.
Lexer and parser updates land together so the entire surface
matches the spec.

**Lexer**

- New tokens: `fat_arrow` (`=>`), `kw_asm`, `kw_bake`.
- `then` and `do` remain reserved keywords (the parser uses them
  for friendly migration diagnostics).
- `0x...` hex literals are rejected with a hint pointing at the
  `$...` form.

**Parser**

- `if` / `elif` heads end at the newline — no `then` required.
  Writing `if cond then …` surfaces a clear diagnostic.
- `while` / `for` heads end at the newline — no `do` required.
  Writing `while cond do …` surfaces a clear diagnostic.
- `match` arms use `case PAT => BODY` instead of `case PAT then
  BODY`; the legacy `then` form errors with a hint pointing at `=>`.
- Short lambda form `|x| x*2`, `|x, y| x + y`, `|| read_input()`,
  with optional type annotations (`|x: i16| -> i16 x*2`). Desugars
  to a `LambdaExpr` whose body is a single `return <expr>`.
- `asm "<instruction>"` is now a builtin statement (§4.11); the
  legacy `@asm("...")` annotation form errors with a migration
  diagnostic.
- Labeled loops: `<while|for> head :label`, with `break :label`
  and `continue :label` targeting the labeled loop. Unlabeled
  jumps still target the innermost loop. `WhileStmt` / `ForStmt`
  gain a `?Span` label field; `break_stmt` / `continue_stmt` move
  from `SpanOnly` to a new `LoopJumpStmt { label, span }` struct.
