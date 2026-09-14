---
bump: minor
---

A checked program says which declaration each name resolves to.

The type-checker resolved every reference against its scope and kept
only the resulting type. `CheckedProgram.bindings` keeps the
resolution: reference offset → the declaration's kind, span and name.

That is what an editor needs. Go-to-definition is `decl_span`, hover is
`kind` beside the type already in `expr_types`, and find-references is
the map read backwards — for `gero lsp` and for a browser host at once,
since both reach the same table rather than deriving bindings a second
time from the AST.

The table is built whether or not the program checks, because an editor
wants hover most in a buffer that does not compile. It covers names and
member accesses, and resolves shadowing to the inner declaration. For an
imported name the span is the `use` that imported it and `module` names
where to look: the checker runs per module and does not hold another
module's table.
