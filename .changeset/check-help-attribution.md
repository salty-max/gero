---
bump: patch
---

`gero check` prints the `help:` line again.

Attributing diagnostics to their originating file rebuilt each one
field by field, which silently dropped everything the rebuild did not
name: the `help:` block and the secondary spans. Every "did you mean"
suggestion the checker computed was therefore invisible on the command
line, while the library tests that read the diagnostic directly kept
passing.

Secondary spans are now remapped into their own file's offsets, and
one that belongs to a different file is dropped rather than drawn at
the wrong bytes — the renderer underlines against a single source.

In the multi-file listing the `help:` line is also indented to sit
with the `error:` it explains, instead of at column zero.
