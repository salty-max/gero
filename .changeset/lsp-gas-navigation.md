---
bump: minor
---

`gero lsp` answers go-to-definition, hover, find-references and
completion for `.gas`.

Assembly had diagnostics and formatting and nothing else, so jumping
to a label — the navigation you reach for constantly in asm, and the
one a banked program spread across files needs most — meant searching
by hand.

All four read the assembler's own symbol table. `asm.Symbol` already
records where each label and constant was declared, so declarations
needed nothing new; references are collected from the parse tree when
the server asks, which keeps the walk out of every `gero asm` run.

A local label is mangled to the key its declaration was stored under,
the same way codegen does it, so `.loop` written under `main` resolves
to `main.loop` — and two locals of the same spelling under different
parents stay distinct.

Hover reports the address a name assembled to: `emit @ $0018`,
`const PRINT = $0010`, with the bank where the symbol sits in one. In
asm a name is its value, so that is the question a reader has at every
use site. It is only knowable after a successful assemble, so a file
that does not assemble reports the kind and nothing more.

Results are positioned through the include graph, so a definition in
an `include`d file lands in that file, and references to a constant
used on both sides of an `include` come back against both URIs.

Semantic tokens are now documented as out of scope rather than
unbuilt: the tree-sitter grammars already cover Gero's tokens, and the
casing convention answers the type-versus-value question a grammar
would otherwise guess at.
