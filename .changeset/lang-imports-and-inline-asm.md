---
bump: minor
---

Inline assembly (`asm "<instruction>"`) now lowers (§4.11). A `{name}`
operand resolves to the named local / parameter's stack slot, the
single instruction is assembled through the asm layer, and its bytes
are emitted in place. A form with no matching opcode is a compile
error (`E_CODEGEN_INLINE_ASM`) instead of a silent `hlt`.

Multi-file imports got three fixes:

- **`use X as Y from "./mod"` renames now bind.** A quoted-path import
  alias resolves to its real exported symbol for every kind — class,
  `def`, `const`, `struct`, `enum` — across calls, `@static` calls,
  constructors, type annotations, `match` arms, and `is` tests.
- **A module imported from several `use` sites is fused once.** Two
  selective imports from the same file no longer redefine its decls.
- **Selectively-imported stdlib functions lower when called bare.**
  `use rng from math` then `rng()` now compiles like `math.rng()`
  (renames included), and resolves its return type at type-check.

A real binding always shadows an import of the same name. New
diagnostics: a `use` cycle is reported (not silently fused), an import
alias bound to two different targets is an error
(`E_USE_DUPLICATE_ALIAS`), and a selective import of a non-existent
stdlib member is caught at the `use`. Tab-separated `use … from … as`
directives and a `from`/`as` inside a trailing comment now parse
correctly.

A focused `docs/examples/modules.gr` (plus its `./io` stub) exercises
these import forms end-to-end.
