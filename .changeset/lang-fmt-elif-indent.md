---
bump: patch
---

`gero fmt` now indents `elif` arms to match their `if`. The `.gr`
printer emitted `elif` at column 0 regardless of nesting depth, so any
`if`/`elif` chain inside a function (or any indented block) came out
misaligned. `elif` arms now carry the surrounding indent, like the
`if` and `else` lines around them.
