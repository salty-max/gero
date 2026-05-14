---
bump: patch
---

`gero fmt` now respects `; gero-fmt-ignore-*` directives — same
opt-out pattern as `// prettier-ignore` / `#[rustfmt::skip]` —
letting users preserve hand-formatted regions through the
canonicalizer:

- `; gero-fmt-ignore-file` in the leading comment block → fmt is
  a no-op on the whole file
- `; gero-fmt-ignore-start` … `; gero-fmt-ignore-end` → statements
  between the markers are source-sliced verbatim
- `; gero-fmt-ignore-next` → the immediately following non-comment
  statement is preserved
- trailing `; gero-fmt-ignore` on the same source line as a
  statement → that line is preserved (alignment + trailing comment
  both stay intact)

The directives are idempotent across re-formats. Concretely, this
means `examples/asm/*.gas` can keep their hand-tuned `const`-block
alignment by adding `; gero-fmt-ignore-file` at the top — opt-in
per file.

Required a parallel fix to `src/asm/expr.zig::skipBlanks` so it
stops at `;` instead of silently eating trailing comments mid-
expression (previously, trailing comments after a `const` RHS or
inside `data8`-list expressions were dropped before reaching the
AST). The parser's outer loop now captures them as first-class
`Comment` statements.
