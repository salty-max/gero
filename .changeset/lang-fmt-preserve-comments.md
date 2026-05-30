---
bump: minor
---

`gero fmt` on `.gr` sources now preserves comments. The lexer captures
each `-- …` line comment as a side-table (off the token stream, so the
grammar is unaffected), the parser carries it on `ParseTree.comments`,
and the printer re-emits leading, standalone, and trailing comments at
their statement / field / case / arm boundaries. Formatting is lossless
and idempotent — previously every comment was silently dropped.

Also fixes a formatter bug where an abstract method (`@abstract def
f(self) -> T` with no body) was emitted with a spurious `end`,
corrupting the enclosing class. `hasAnnotationNamed` was a stub that
always returned `false`; it now actually inspects the annotation so a
body-less `@abstract` def round-trips without an `end` while an
empty-bodied regular `def f() end` keeps its `end`.

`gero.lang.print` takes an additional `comments` slice; pass `&.{}` when
comment fidelity isn't needed (AST round-trip callers). `gero.lang.Comment`
is re-exported on the barrel.
