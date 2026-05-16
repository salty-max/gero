---
bump: minor
---

`gero.lang.parse` lands — the recursive-descent parser that
consumes the lexer's `TokenStream` and emits an `ast.Program`.
Covers every statement and expression form in gero-lang §3-§6.

The same PR locks down the **gero-lang v1 spec** in
`docs/gero-lang.md` so the language shape is final before the
typechecker and codegen land on top.

**Parser surface:**

- Declarations: `let` / `const` / `def` / `lambda` / `class` /
  `struct` / `enum` / `use` (whole-module, aliased, selective,
  quoted-path), plus `local` visibility shim
- Control flow: `if` / `elif` / `else` (with `if let pat =
  expr when guard` shape), `while` (with `while let`), `for-in`
  with optional `step`, `match` with patterns + guards, `do…end`
  as both statement and expression, `return` / `break` /
  `continue` / `print` / `defer`
- Patterns: wildcard, ident binding, literal, or-pattern,
  range-pattern, tuple, struct (with shorthand), enum variant
- Type annotations: primitives, `T?` nullable, `[T; N]` arrays,
  `Vec(T)`, tuples, `fn(args) -> ret`
- Assignment forms: plain `=`, every compound `+=` / `-=` /
  `*=` / `/=` / `%=` / `&=` / `|=` / `^=` / `<<=` / `>>=`,
  statement-only `++` / `--`, `_ = expr` discard
- Pratt-precedence expression parser per §4.2.1, including the
  `as` cast operator and `is` variant test
- Annotation attachment: every annotation in §3.7 — `@bank N`,
  `@interrupt N`, `@final`, `@inline`, `@override`, `@private`,
  `@static`, `@abstract`, `@noreturn`, `@test`, `@bench`,
  `@zero_page`, `@addr`, `@volatile`, `@align(N)`, `@cold` —
  paren'd or bare-arg form, multi-annotation stacks, attaches to
  the following `def` / `class` / `struct` / `enum` / `let` /
  `const` / class field / class method
- `@asm("...")` emits a dedicated `asm_stmt` AST node at
  statement position; `@abstract def` declares a method without
  a body.

**Lexer additions:**

- Compound-assign tokens (`+=`, `-=`, …, `<<=`, `>>=`)
- Fixed-point literals (`1.5`, `0.125`, …) pre-encoded as Q8.8
- `$1234` hex literals
- `defer` keyword

**Spec lockdown (`docs/gero-lang.md`):**

- §1 — `let`-mutable-by-default flagged as intentional
- §2.4 — Hex literals are `$...` only; `0x` removed for retro
  consistency
- §2.6 — Adds `asm` and `bake` keywords
- §3.4.4 — New section: References `&T` for pass-by-reference
  without copies, with `&x` prefix and `mem.addr_of(x)` for raw
  `u16` addresses
- §3.5.1 — Type casts (`x as T`) with full conversion table
- §3.7.1 — Adds `@volatile` and `@align(N)`
- §3.7.2 — `@inline` capped at 32 bytecode instructions
  post-lowering; `@cold` lays cold functions after non-cold ones
  deterministically; new `@no_capture` annotation
- §3.7.7 — Reclassifies `@asm("…")` as the builtin `asm`
  statement (§4.11), not an annotation
- §3.8 — New section: `bake` compile-time evaluation for lookup
  tables, palette ramps, RNG seeds
- §4.2 — Adds overflow-explicit operators `+%` / `-%` / `*%`
  (wrap) and `+|` / `-|` / `*|` (saturate); plain `+` / `-` /
  `*` trap on overflow in debug builds, wrap in release builds.
  MMIO assignment via `@addr @volatile` bindings.
- §4.4 — Removes `then` after `if` / `elif` heads
- §4.5 — Removes `do` after `while` / `for` heads
- §4.5.4 — New: labeled `break :label` and `continue :label`
- §4.6.1 — Tail-call optimization on direct `return self_or_sibling(args)`
- §4.6.2 — User-defined variadic parameters (`args: ...`)
- §4.7.1 — Short lambda form `|x| x*2` (Rust-style)
- §4.8 — Match arm separator switched from `then` to `=>`
- §4.10 — Defer bytecode-cost section added
- §4.11 — New section: inline `asm "..."` statement
- §5.3.1 — Typed `mem.read_u8 / read_u16 / read_i8 / read_i16 /
  write_*` + `mem.addr_of` builtin; `debug_assert` distinct from
  `assert`
- §6 — `super.<field>` allowed; class-fields-default-public
  documented as intentional
- §9 — Adds explicit out-of-scope notes for raw pointers,
  borrow checker, and the `then` / `do` removal

Public re-exports through `gero.lang`: `ast`, `ParseTree`, `parse`.
