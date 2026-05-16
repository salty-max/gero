---
bump: minor
---

`gero.lang.parse` lands — the recursive-descent parser that
consumes the lexer's `TokenStream` and emits an `ast.Program`.
Covers every statement and expression form in gero-lang §3-§6:

- Declarations: `let` / `const` / `def` / `lambda` / `class` /
  `struct` / `enum` / `use` (whole-module, aliased, selective,
  quoted-path), plus `local` visibility shim
- Control flow: `if` / `elif` / `else` (with `if let pat =
  expr when guard` shape), `while` (with `while let`), `for-in`
  with optional `step`, `match` with patterns + guards, `do…end`
  as both statement and expression, `return` / `break` /
  `continue` / `print`
- Patterns: wildcard, ident binding, literal, or-pattern,
  range-pattern, tuple, struct (with shorthand), enum variant
- Type annotations: primitives, `T?` nullable, `[T; N]` arrays,
  `Vec(T)`, tuples, `fn(args) -> ret`
- Assignment forms: plain `=`, every compound `+=` / `-=` /
  `*=` / `/=` / `%=` / `&=` / `|=` / `^=` / `<<=` / `>>=`,
  statement-only `++` / `--`, `_ = expr` discard
- Pratt-precedence expression parser per §3.3: range < `or` <
  `and` < cmp < `|` < `^` < `&` < shift < add/sub < mul/div <
  `is` < unary < postfix
- Annotation attachment: `@bank N` / `@interrupt N` / `@final` /
  `@inline` / `@override` / `@private` / `@static` / `@abstract`
  / `@noreturn` / `@test` / `@bench` / `@zero_page` / `@addr` —
  paren'd or bare-arg form, multi-annotation stacks, attaches to
  the following `def` / `class` / `struct` / `enum` / `let` /
  `const` / class field / class method

Lexer extended with:

- Compound-assign tokens (`+=`, `-=`, …, `<<=`, `>>=`) — §4.2
- Fixed-point literals (`1.5`, `0.125`, …) — §3.3, pre-encoded as
  Q8.8 (`1.5` → `0x0180`)
- `$1234` hex literals — §3.7.1, sibling to `0x1234`

Diagnostics flow through `core.ParseError` for consistency with the
asm side.

Annotation attachment landed for every spec target (§3.7): `def`,
`class`, `struct`, `enum`, class fields + methods, and module-level
`let` / `const` (so `@bank N`, `@zero_page`, `@addr $1234` reach
codegen). `@asm("…")` emits a dedicated `asm_stmt` AST node at
statement position. `@abstract def` declares a method without a
body.

Public re-exports through `gero.lang`: `ast`, `ParseTree`, `parse`.
