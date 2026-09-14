---
bump: minor
---

`gero lsp` answers find-references and inlay hints for `.gr`.

Find-references reads the binding table backwards: each entry names the
declaration its reference resolves to, so the references to a
declaration are the entries pointing at it. Asking on a use and asking
on the declaration return the same set, because both resolve to the
same declaration first — and neither can disagree with
go-to-definition, since all three read one table.

Inlay hints show the inferred type of each `let` the source left
unannotated, taken from the types the checker recorded for named
bindings. An annotated binder gets none: repeating a type the author
already wrote is noise, and the point of the hint is to show what was
inferred rather than what was stated.

Results come back in source order rather than in whatever order the
map stored them.
