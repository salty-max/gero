---
bump: minor
---

`gero compile` now lowers compound assignment (`+=`, `-=`, `*=`, `/=`,
`%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`) and the `++` / `--` statements.
Each desugars to its plain-assignment form (`a op= b` → `a = a op b`,
`x++` → `x = x + 1`) and reuses the existing store path, so it works
for the same targets `=` supports — local / param / global identifiers
and class fields. Previously these emitted `E_CODEGEN_UNSUPPORTED`.

Adds `examples/lang/factorial.gr` — an iterative factorial exercising
`*=` / `-=` in a `while` loop.
