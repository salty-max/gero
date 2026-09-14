---
bump: minor
---

`gero lsp` answers go-to-definition and hover for `.gr`.

Both read `CheckedProgram.bindings` — the table the type-checker now
keeps of which reference binds to which declaration. Nothing re-derives
names from the AST, which would be a second implementation agreeing
with its author rather than with the compiler, and drifting from it.

Hover shows the name, its inferred type where there is one, and what
kind of declaration it is, naming the module for an imported name. A
position on something the checker did not bind — a keyword, a comment,
a name that does not resolve — answers `null` instead of guessing.

Both work in a buffer that does not compile, which is when an editor
is asked most.

`docs/lsp.md` §6 described all six resolved-name features as blocked on
exactly this table. It now describes what is provided and what is
merely unbuilt.
