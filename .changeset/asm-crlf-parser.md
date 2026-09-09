---
bump: patch
---

The assembler accepts CRLF source. `docs/asm.md` §2 says "CRLF and LF
are both accepted; classic-Mac CR is not", and the lexer implemented
that — but the parser is a separate path over the same bytes and knew
only `\n`, so every line of a `.gas` file saved with Windows line
endings failed with "unrecognized statement" at the column of the `\r`.

A bare CR is still refused, per the same rule.
