---
bump: minor
---

feat(apps/gero-cli): `gero lsp` — a language server for `.gas` and `.gr`

Speaks LSP over stdio, serving diagnostics and formatting for both
front-ends from one binary. Diagnostics are the same ones `gero check`
reports — the gero-lang pipeline is now a single shared function both
commands call — and formatting is the same output `gero fmt` writes.

Analysis resolves the whole `use` / `.include` graph rooted at the
document, reading every file the editor holds open from its buffer
rather than from disk. The server records which files each document
read, so changing a library re-checks every open document that imports
it — editing a library reddens its importers with no save in between.
Diagnostics are published against the file they came from, in that
file's own coordinates.

Library: `resolveUseImportsOverlaid` and `resolveIncludesOverlaid`
resolve an import graph against in-memory buffers; `Overlay` names the
path → text map they take.
