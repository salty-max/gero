---
bump: minor
---

Tuple support is now complete (§3.4) — the five combinations deferred
from the initial tuple PR are lowered.

- **Structural `==` / `!=`** — element-wise, mirroring struct equality:
  an all-scalar tuple byte-compares; a `str` element compares by content
  (§3.2.1); a nested struct / tuple / payload-enum element recurses.
  Ordering operators stay rejected.
- **Whole-tuple `print`** — renders `(v0, v1, …)`, each element by its
  type (recursing into nested structs / tuples / enums). A struct with a
  tuple field renders it inline too.
- **Nested aggregate elements** — a tuple element may itself be a struct
  (`(P, i16)`) or a tuple (`((1, 2), 3)`), and a struct may have a tuple
  field (`S { p: (i16, str) }`); they lay out inline and `.N` / `.field`
  access addresses them. Chained `t.0.1` now parses (the parser splits
  the `0.1` the lexer folds into a fixed literal).
- **Element store** — `t.N = x` (and `t.N += …` / `t.N++`) assigns into
  a tuple element; `.N` is a place expression. Storing into an aggregate
  element is a clean `E_CODEGEN_UNSUPPORTED`.
- **Return from `@inline`** — a tuple-returning `@inline` function
  materializes its result into the caller frame, like the struct path.

Folded in while completing the above:

- **`@inline` expansion frames are caller-prologue-backed** — every
  inline call-site's args, return slot, and body inner locals are now
  reserved up front by the caller's prologue (`countFrameBytes` walks the
  inline call graph) instead of self-backing with `sub sp` at expansion
  time. Inline slots therefore sit above the entry `sp`, where pushed
  operands never reach, so a mid-expression inline call no longer aliases
  live stack. Fixes a family of silent miscompiles: `sq(3) + sq(4)` (two
  inline calls in one expression), `mk(a, b).x` where the body has inner
  `let`s feeding a returned aggregate, and `==` / `!=` on `@inline`-returned
  structs / tuples — all of which previously read clobbered bytes.
- **Interpolated strings allocate per evaluation** (§3.2.2) — a fresh
  heap buffer each time, so two evaluations of the same `"…$(x)…"` (e.g.
  a value returned from a function called twice) no longer alias; the
  earlier binding kept its own bytes. Replaces the static per-site buffer.
- **`E_CODEGEN_DATA_OVERFLOW`** now guards the data-global region itself
  (a global past the region ceiling is flagged), matching its documented
  scope instead of riding on the removed interpolation buffer.
- **Interpolating a non-scalar value renders it** — `"$(s)"` where `s` is
  a struct / tuple / enum now formats the value's default rendering
  (§4.9) into the string, instead of formatting its address as an
  integer. The same renderer drives `print` and `$(…)`.
- **`$$` collapses to a literal `$`** (§3.2.2) — the escape was passing
  through verbatim; the string decoder now folds it (a lone `$`, e.g.
  `$5`, is untouched).
