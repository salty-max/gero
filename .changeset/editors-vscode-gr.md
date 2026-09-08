---
bump: minor
---

feat(editors): VS Code highlights `.gr`

`vscode-gero` v0.4.0 adds a second language contribution for gero-lang:
a TextMate grammar, and a language config with the `--` comment toggle
and indent rules that open on a block head and close on `end` / `else`
/ `elif` / `until` / `case`.

That closes the last editor gap. Both languages now have a tree-sitter
grammar for the editors that consume one, a TextMate grammar for those
that don't, and diagnostics + formatting from `gero lsp`.

Scopes were verified by tokenizing the example corpus with
`vscode-textmate` rather than by reading the grammar.
