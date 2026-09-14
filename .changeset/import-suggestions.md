---
bump: minor
---

An unresolved stdlib name suggests the import that would bind it, and
`gero lsp` offers it as a quick-fix.

`abs(x)` without a `use` reported `undefined symbol` and stopped
there, though the compiler holds the tables that say `abs` is
`math`'s. It now adds ``help: `abs` is in the stdlib — add `use abs
from math` ``, and the editor offers an action that inserts the line.
A near spelling already in scope still wins: a name one edit from a
local is far more likely a typo than a reach for the stdlib, and the
import is the more disruptive of the two corrections.

`W_UNUSED_IMPORT` gains the opposite action, which removes the line.
Applying both in turn on a file that imports what it does not use and
uses what it does not import leaves it clean.

`Diagnostic.fix` carries these as a union rather than a bare name,
because an import is not a rewrite of the span that reported it. Each
variant says what to change, not how to write it — where an import
belongs depends on the file's existing `use` lines, which is the
editor's to know. It reaches `--format=json` as a `fix` object too.
