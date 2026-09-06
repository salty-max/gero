---
bump: patch
---

`gero test` and `gero bench` no longer run an imported module's entries
once per file that reaches them. Discovery collected annotated defs
from the whole fused program, so a `@test` in `src/util.gr` ran twice
under the natural `[test].include = ["."]` — once found directly, once
through `main.gr`'s `use` graph. Each module's entries now come from
that module alone, which is the "each module is parsed and type-checked
once" cli.md §3.4 describes.
