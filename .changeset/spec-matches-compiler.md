---
bump: patch
---

`gero check` now refuses `break` / `continue` outside a loop
(`E_LOOP_OUTSIDE`) and a labeled jump that matches no enclosing
loop (`E_LOOP_UNKNOWN_LABEL`). Both used to slip through typecheck
and fail only at codegen under an internal code.

Five diagnostic codes that nothing ever emitted are gone from
`lang-diagnostics.md`. Thirteen that the compiler already produced
were missing from the registry and are listed. A `verify` gate
diffs meaning table, registry, and emit sites so the three cannot
drift again.

`gero-lang.md` no longer documents `Vec.map` / `.filter` / `.fold`,
`str.slice`, first-class ranges, tail-call reuse, `let else`,
file-level `@bank`, or `-> noreturn` — none of them exist. A `for`
loop does the three Vec helpers; `map` would allocate a second
vector on 64 KB.
