---
bump: patch
---

test: a golden bytecode corpus, gated in CI

Nothing noticed when a codegen change altered the bytes of a program
that still ran correctly. The example gates assemble, type-check, run,
and diff stdout — every one of them stays green through an accidental
ABI change. That was tolerable before a format freeze and is not after
it, when byte stability is the promise being made.

`tests/golden/` now holds one blessed `.gx` per example, and
`zig build golden` recompiles each and compares. It runs in `verify`,
in `ci`, and on pull requests.

The comparison is not plain byte equality, which would be wrong in
both directions:

- The header, base image, and banks are compared byte for byte — a
  header regression is exactly the kind this catches, and the
  assembler shipped one for months.
- The debug section is compared by content. Symbol order is an
  emission detail, so a permutation must not fail the gate, while a
  changed symbol or line-table row must.

A failure names the file, the first differing offset, both bytes, and
which region of the archive it falls in. Re-blessing is
`zig build bless-golden`, documented alongside a warning not to reach
for it before knowing which change moved the bytes.
