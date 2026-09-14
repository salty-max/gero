---
bump: minor
---

`gero lsp` offers quick-fix code actions for `.gr`.

When a name does not resolve, the type-checker already looks for the
closest spelling in scope and writes `help: did you mean \`x\`?`. It
threw `x` away afterwards, leaving a tool that wanted to apply the fix
to parse the name back out of an English sentence. `Diagnostic` now
carries it as `suggestion`, the bare name, so a `textDocument/
codeAction` is a `TextEdit` replacing the diagnostic's own span with
what the checker decided.

Nothing re-derives the correction, which means an action can never
disagree with the diagnostic offering it, and a diagnostic the checker
found no candidate for offers no action rather than a guess. All five
suggesting diagnostics are covered: an undefined symbol, an undefined
type, a struct or class field, a class method, and a `mem` builtin.

The document is re-analyzed for the request rather than served from
what was last published — a client sends its own copy of the
diagnostics in `context`, and those describe the buffer as it was when
they were published.
