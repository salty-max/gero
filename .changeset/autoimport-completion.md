---
bump: minor
---

Completion offers names you have not imported, and imports them when
you accept one.

Typing `fixed_s` with no `use` line now offers `fixed_sin`, marked
`from math`, and accepting it inserts `use fixed_sin from math` in the
same keystroke. The same holds for a name declared in another file in
the workspace, which arrives as `from "./geometry"`. Previously the
only route was to type the name, get `undefined symbol`, and take the
quick-fix afterwards.

Importable names are gated on a prefix and sorted after the ones
already in scope: every stdlib export and every name in the workspace
appearing at an empty cursor would bury the handful that are genuinely
available. Because the set depends on the prefix, the reply is marked
`isIncomplete` so a client asks again rather than re-filtering a list
computed for a longer one.

A name already in scope is offered once, without an import.
