---
bump: patch
---

Go-to-definition, hover and find-references work on type names.

The checker recorded a reference only where a name was inferred as an
expression, which left every type position out of the binding table. A
struct used as a parameter type, a return type, an annotation and a
struct literal recorded nothing at all; an enum named in an annotation
and in a `case` arm recorded nothing; a parent class after `extends`
recorded nothing. Asking an editor about any of them answered `null`,
and find-references on a struct returned an empty list rather than the
places it is used.

Each of those positions now records the reference. The ones that
resolve a name against a registry — `State.Idle`, `Player.spawn()`,
`case State.Idle` — never infer the receiver as an expression, so they
record it themselves rather than inheriting it from the value path.
