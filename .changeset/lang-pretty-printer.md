---
bump: minor
---

`gero.lang.print` lands — canonical `.gr` pretty-printer per
issue #231. Closes the lang front-end: parser produces an `ast.Program`,
printer reverses it back to source.

What it does:

- Walks every AST node (statements, expressions, patterns, type
  annotations) and re-emits canonical syntax per `docs/gero-lang.md`.
- Slices identifier names, char literals, string parts, format specs,
  and numeric literals from the original source span — so hex (`$FF`),
  binary (`0b…`), and decimal forms round-trip byte-identical instead
  of normalizing to one base.
- Re-emits structural shape from the AST itself: keywords, indentation
  (2-space), block bodies, annotation lines.
- Short lambda form `|x| body` re-emerges from a `LambdaExpr` whose
  body is a single `return <expr>`.
- Match arms use `case PAT => BODY` with single-line bodies inlined
  after `=>` when the body is a one-statement expression-like form.
- Loop labels (`:label`) re-emit on `while` / `for` / `repeat` heads.
- `bake def` / `bake do` flags re-emit the keyword prefix.
- Annotations stack above their decl, one per line.
- Quoted-path imports (`use "./physics"`) preserve the surrounding
  quotes from the captured span.
- Minimum-paren printing for binary operators using Pratt precedence
  — `a + b * c` stays paren-free, `(a + b) * c` keeps the parens
  that change associativity.

Round-trip property:

    parse(print(parse(s))) == parse(s)

The printer is idempotent on its own output — re-parsing + re-printing
yields byte-identical text. Tests cover the property on a J-RPG loop
sketch, an annotation stack, a pattern-matching switch, nested
expressions, and HOF chains.

Public re-export via `gero.lang.print`. New module
`src/lang/print.zig` mirrors test at `tests/lang/print.test.zig`
(63 tests: per-variant coverage + idempotency property).
