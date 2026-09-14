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
member accesses, resolves shadowing to the inner declaration, and
crosses module boundaries — a name imported with `use` points at the
declaration in the file that declares it, not at the import.

The assembler gained the same thing: a `Symbol` records where its label
or constant was declared, so the two front ends answer the question the
same way.
