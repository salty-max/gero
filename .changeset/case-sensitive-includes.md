---
bump: minor
---

`include` and `use` resolve case-sensitively on every host. macOS and
Windows volumes usually ignore case, so `include "Utils.gas"` found
`utils.gas` there and nothing on Linux — a program built on the
author's machine and failed in CI with a diagnostic about a file that
plainly exists. The virtual file set already compared keys exactly, so
the two halves of one feature disagreed.

A mismatch is now `E021` in asm and `E_USE_CASE_MISMATCH` in gero-lang,
reported at the line that wrote it. Absolute paths are exempt: they are
the author's own and may traverse a symlink whose real name differs.

Programs that relied on a mis-cased include will now fail — on the host
where the spelling is wrong, rather than on someone else's.
