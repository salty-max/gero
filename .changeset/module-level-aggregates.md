---
bump: patch
---

A module-level `let` can hold a struct, tuple or array.

`let ball: Ball = Ball { x: 160, y: 120 }` type-checked and then
failed to lower with `E_CODEGEN_UNSUPPORTED`, though `lang.md` §4.4
says a top-level initializer runs at program start like any other.
Scalars worked; aggregates did not.

The startup path stored each initializer through the accumulator,
which holds one value. An aggregate is now materialized into a frame
slot — the same way a destructuring `let` already built one — and its
bytes copied into the global's storage.

This is the shape a program with state reaches for first: the
world, the player, the level. It failed on the first line.
