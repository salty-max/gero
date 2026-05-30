---
bump: minor
---

`gero compile` now lowers payload-carrying enum variants — construction
and `match` extraction. Previously `E.A(5)` and `case E.A(n)` emitted
`E_CODEGEN_UNSUPPORTED`.

Per spec §3.6, an enum with any payload variant is represented as a
`[tag | payload]` slot addressed by pointer (heap-allocated like a class
instance); payload-free enums stay a bare register tag, so simple enums
pay nothing. Construction writes the tag and each payload field at its
offset; `match` reads the tag from the slot, dispatches, and binds each
payload field to a local — usable in the arm's `when` guard, body, and
nested expressions. The `is` test reads the tag from the slot too.

Pairs with the type-checker change that types payload binders from the
variant's declared fields, so `case E.A(n)` gives `n` its real type
(no `any`/unknown). Adds `examples/lang/shapes.gr`.
