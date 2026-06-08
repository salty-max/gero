---
bump: minor
---

`do … end` now lowers as an **expression** (§4.3): `let x = do … end`
runs the block's scoped statements and evaluates to its last
expression — for any result type, including tuples, structs, and
arrays. The block's inner locals are reserved in the enclosing frame,
and its defers fire without clobbering the value.

Closure **capture analysis is reworked** to be scope-correct and to
cover the cases the previous flat walker missed:

- Variables used inside `$(…)` string interpolation (and the other
  sub-expression shapes the free-variable walker had skipped) are now
  captured, so `|| -> str "score: $(score)"` resolves `score`.
- A capture shadowed by a block / loop / `match`-arm local is scoped
  out at the inner scope's end, so the outer binding resolves again
  afterward.
- A free function, class, enum, or struct named in a lambda body is no
  longer mistaken for a capture — the body addresses it directly.
- A captured parameter that escapes its function is kept alive, reading
  and writing its current value.

Closures can now capture **`self`** (a method-defined lambda reads the
receiver from its env) and **inline aggregates** — structs, arrays,
tuples, `Vec`, and scalar optionals. Following §4.7.2: a read-only
aggregate is copied at construction (value semantics, escape-safe); an
aggregate the closure mutates becomes a shared heap upvalue, so writes
are visible to the enclosing scope and to every closure over it.

Together these let `docs/examples/syntax_overview.gr` — the
complete-syntax tour — type-check and lower end-to-end; it is no
longer `fmt-only`.
