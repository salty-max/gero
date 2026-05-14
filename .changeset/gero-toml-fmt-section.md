---
bump: minor
---

`gero.toml` gains a `[fmt]` section — per-project printer
overrides for `gero fmt`.

```toml
[fmt]
indent = 2                   # default 2
comment_column = 30          # default 30 — 0 disables alignment
align_kv = true              # default true
hex_case = "upper"           # upper | lower | preserve
```

Inside a project, `gero fmt` (and `gero fmt --check`) reads the
section and applies the overrides; outside a project (or with no
`[fmt]` section), compile-time defaults are used — preserves the
single-file CLI behavior.

Same pattern as Rust's `rustfmt.toml` / Black's `pyproject.toml
[tool.black]`: one canonical shape per project, no in-file
overrides, no editor-side `.editorconfig` discovery.

TOML parser extended with integer + boolean value shapes (keys
`indent`, `comment_column` parse as integers; `align_kv` as a
bool; `hex_case` as one of three allowed strings).

`Diagnostic` storage moved inline (embedded `[256]u8 +
message_len`) so the message slice survives `parseWithDiagnostic`
returning — fixes a latent dangling-slice bug that only surfaced
with longer error messages (the existing tests happened to use
short messages and read intact stack memory by luck).
