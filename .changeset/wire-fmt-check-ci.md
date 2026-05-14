---
bump: patch
---

`gero check` + `gero fmt --check` are now wired into the local CI
gate and the lefthook pre-commit hook:

- `zig build fmt-check-examples` — new step that asserts every
  `examples/asm/*.gas` is canonical; failing the gate signals
  spec drift on the printer side
- `zig build ci` — now runs `check-examples` → `check-broken` →
  `fmt-check-examples` → `test-examples` in order
- `.github/workflows/ci.yml` — Example-integration job picked up
  the same three new steps alongside the existing `test-examples`
- `lefthook.yml` pre-commit — runs `gero check --quiet` and
  `gero fmt --check --quiet` on staged `.gas` files; requires a
  built binary (`zig build` once after a fresh clone)

The printer's canonical form was relaxed to **source-driven**
blank-line + comment-indent preservation so users can canonicalize
existing hand-written `.gas` without losing readability cues. The
default `comment_column` moved from 32 → 30 to match the column
the `examples/asm/` files were written at.

In-tree `examples/asm/*.gas` were canonicalized as part of this
change (one-time mass rewrite). After this, the new
`fmt-check-examples` CI gate keeps them canonical going forward.
