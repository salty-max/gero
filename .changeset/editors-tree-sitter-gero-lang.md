---
bump: minor
---

feat(editors): a tree-sitter grammar for `.gr`

`salty-max/tree-sitter-gero-lang` v0.1.0 is wired under `editors/`
beside the asm grammar and the VS Code extension, so a gero-lang buffer
gets highlighting, folding and indentation in any tree-sitter editor.

Until now that was `.gas`-only: the docs described a `.gr` buffer as
colourless but fully checked, since diagnostics and formatting already
came from `gero lsp`. The split is now the one those docs always
described as the better answer — the grammar colours the buffer, the
server checks it.

`docs/tooling.md` carries the Neovim and Helix setup. It is not the asm
recipe with the names swapped: gero-lang terminates statements at a
newline, so the grammar has an external scanner and the compile step
needs `src/scanner.c` alongside `src/parser.c`.

VS Code still targets the assembler only.
