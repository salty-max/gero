---
bump: minor
---

`ifdef` / `ifndef` / `endif` directives ship — NASM/ca65-style
conditional assembly with include-guard semantics.

```asm
; hardware.gas — included from every code file that touches PPU/APU
ifndef HARDWARE_INCLUDED
const HARDWARE_INCLUDED = $01
const PPU_CTRL = &2000
struct Sprite { x: u8, y: u8, tile: u8, attr: u8 }
endif
```

Re-including the file from a second ancestor is now a clean no-op
instead of a duplicate-`const` cascade.

## Semantics

- `ifndef NAME` opens a block emitted only when `NAME` is **not**
  bound as a `const`. `ifdef NAME` is the inverse.
- "Bound" inspects the `ConstantTable` built incrementally as the
  parser walks statements top-to-bottom. So `ifndef X` placed
  **before** `const X` is true; placed **after**, false. Same
  ordering rule as NASM `%ifdef`.
- Skip-mode (false branch) discards tokens until the matching
  `endif` — no AST, no diagnostics, no emit-cursor advance.
- Blocks nest: a nested `ifdef` inside a skipping outer frame
  is also skipped regardless of its own predicate, but its
  matching `endif` still pops the right frame.
- The check only inspects `const` names; labels and `data8` /
  `data16` symbols aren't queryable (the explicit-`const` sigil
  is the include-guard convention).

## New error codes

- **`E018`** — `endif` without a matching `ifdef` / `ifndef`.
- **`E019`** — `ifdef` / `ifndef` block left open at EOF.

## Why now

Required for any non-trivial gtx-16 cart: a multi-bank game
inevitably shares hardware-register / struct-layout headers
across 5-20 source files. The pre-`ifndef` workarounds
("single-root include" or "one giant file") forced an
anti-pattern at any scale beyond hello-world.

The asm spec (`docs/asm.md` §2.2) now documents the three
directives + the include-guard idiom; `docs/asm-cookbook.md`
ships a new recipe **8. Include guards** as a worked example.

## Out of scope

`else` / `elif` / `if` (boolean expressions). The pure
`ifndef` / `endif` pair covers include-guards completely; richer
forms can land later once a use case appears.

Editor highlighting (tree-sitter + VS Code TextMate) is tracked
separately in salty-max/tree-sitter-gero-asm#4 and
salty-max/vscode-gero#2.
