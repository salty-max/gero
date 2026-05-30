---
bump: minor
---

`gero fmt` and `gero check` now cover `.gr` (gero-lang) sources, not
just `.gas`.

`gero fmt main.gr` parses via the gero-lang front-end and re-emits
through the AST printer, with the same in-place / `--check` (exit 8) /
directory-walk UX as the asm path. `gero fmt --stdin --lang=gr` formats
gero-lang from stdin for editor format-on-save — stdin carries no
filename to dispatch on, so the new `--lang=<gas|gr>` flag picks the
front-end explicitly (defaults to `gas`; ignored in path mode, where
the extension decides). Directory walks format `.gas` and `.gr`
together.

`gero check main.gr` routes to the parser + type checker (no codegen)
and renders the same caret diagnostics and `--format=json` jsonl as the
asm path. Mixed `gero check src/` invocations walk both file kinds.

Fixes a double-reporting bug in the `.gr` check path: `parse` already
folds the lexer's `stream.errors` into `tree.errors`, so the previous
code surfaced every lexer diagnostic twice.

Closes #200.
