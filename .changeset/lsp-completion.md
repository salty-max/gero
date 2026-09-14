---
bump: minor
---

`gero lsp` answers completion for `.gr`.

Completion asks something the binding table cannot: that table maps
references that exist, and completion is about names that do not yet.
So the type-checker now records `CheckedProgram.visible` — every
declaration together with the range of the scope it was declared in.
The scopes themselves are opened and closed during the walk and are
gone long before an editor asks, so the range is written down while it
exists rather than reconstructed afterwards.

A name is offered when its scope covers the cursor and it was declared
before the cursor: a `let` is not in scope on the line above itself,
and a local in one function is not offered inside another. A
module-level declaration is visible throughout the file, including
above its own line, which is how a `def` already behaves.

Offering a name that is not in scope is what makes a completion list
untrustworthy, so the tests assert the absences as well as the
presences.
