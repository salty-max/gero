---
bump: minor
---

Apply the spec-locked syntax decisions from `docs/gero-lang.md` v1.
Lexer and parser updates land together so the entire surface
matches the spec.

**Lexer**

- New tokens: `fat_arrow` (`=>`), `kw_asm`, `kw_bake`, `kw_repeat`,
  `kw_until`.
- `then` is no longer a reserved word (becomes an identifier);
  `do` remains reserved for `do … end` blocks (§4.3).
- `0x...` hex literals are rejected with a hint pointing at the
  `$...` form.

**Parser**

- `if` / `elif` heads end at the newline — no `then`.
- `while` / `for` heads end at the newline — no `do`; the parser
  rejects a stranded `do` after a loop head.
- `match` arms use `case PAT => BODY`.
- Short lambda form `|x| x*2`, `|x, y| x + y`, `|| read_input()`,
  with optional type annotations (`|x: i16| -> i16 x*2`). Desugars
  to a `LambdaExpr` whose body is a single `return <expr>`.
- `asm "<instruction>"` is a builtin statement (§4.11). `@asm("...")`
  as an annotation is rejected with a clear error pointing at the
  statement form.
- Labeled loops: `<while|for> head :label`, with `break :label`
  and `continue :label` targeting the labeled loop. Unlabeled
  jumps still target the innermost loop. `WhileStmt` / `ForStmt`
  gain a `?Span` label field; `break_stmt` / `continue_stmt` move
  from `SpanOnly` to a new `LoopJumpStmt { label, span }` struct.

**Repeat-until loop (§4.5.4)**

`repeat … until cond` — Lua/Pascal-style do-while loop. Body runs
at least once; loop exits when the trailing expression evaluates
true. No `end` (the `until <cond>` line terminates). Labels work
as on `while` / `for`. Adds `kw_repeat` / `kw_until` keywords and
a new `RepeatStmt { body, cond, label, span }` AST node.
