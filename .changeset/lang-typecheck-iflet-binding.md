---
bump: patch
---

`if let` and `while let` now bind their pattern variables into the
guard and body scope. Previously the typechecker inferred the matched
expression but never registered the bindings, so `if let E.A(n) = e
when n > 0` reported `n` as an undefined symbol in both the `when`
guard and the body (§4.4.1 / §4.5.1). The checkers now open a child
scope and register the pattern bindings before walking the guard and
body — mirroring `match`-arm scoping.
