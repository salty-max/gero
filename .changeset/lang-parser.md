---
bump: minor
---

`gero.lang.parse` lands — the recursive-descent parser that
consumes the lexer's `TokenStream` and emits an `ast.Program`.
Covers every statement and expression form in gero-lang §4:

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

Lexer extended with compound-assign tokens (`+=`, `-=`, …,
`<<=`, `>>=`) needed by the parser. Diagnostics flow through
`core.ParseError` for consistency with the asm side.

Public re-exports through `gero.lang`: `ast`, `ParseTree`,
`parse`.
