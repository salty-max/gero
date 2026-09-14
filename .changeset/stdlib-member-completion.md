---
bump: patch
---

`math.` completes to the functions of `math`.

Completing after a dot read `CheckedProgram.members`, which is built
from declarations the checker walks. The stdlib modules are
compiler-provided and have signature tables rather than declarations,
so nothing was ever recorded for them: `use math` followed by `math.`
offered an empty list, as did `mem.`, `str.`, `bank.` and `test.`,
while a struct or enum completed correctly.

Their names are now recorded as members of whatever the `use` bound
them to — under the alias where there is one, so `m.` after
`use math as m` answers the same way.
