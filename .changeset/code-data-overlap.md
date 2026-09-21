---
bump: patch
---

A program whose code ran past `0x2000` overwrote itself at startup.
Code grows up from `0x1200` and static data from `0x2000`, but nothing
checked that the two stayed apart — and since globals are seeded by
stores in the entry prologue rather than baked into the image, crossing
`0x2000` meant the program's first act was to write its global
initializers over its own instructions. The corruption landed on
whatever happened to sit at the boundary, so the symptom moved with
unrelated edits: a call-site cleanup `add $000E, sp` became `add $000E,
ip` when the low byte of a `$8000` constant replaced the register
operand. The static-data region now sits word-aligned above the code
when the code reaches past `0x2000`, and the bound that rejects an
over-large image is the one that sees the final code length, so the two
regions can no longer overlap silently. A program whose code fits below
`0x2000` compiles to exactly the same bytes as before.

Because a global's address now depends on the code length, a cached
fragment carries the provisional address and is re-resolved by the build
that splices it. `Fragment` gained a `data` field for those slots and
the fragment-file format version moved to 4, so entries written by an
earlier build are discarded rather than reused.
