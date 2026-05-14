---
bump: patch
---

`apps/gero-cli/project.zig` lands — TOML subset parser + `Manifest`
struct + walk-up-ancestors `findManifest` helper. Foundation for
the project-aware subcommands (`gero new`, `gero build`, project-
mode of `check` / `fmt` / `test`) which build on top in their own
sub-issues.

Recognized grammar:

- Section headers `[name]`
- Key-value with double-quoted string literals
- Single-line string arrays `["a", "b"]`
- `#`-comments to end-of-line

Manifest sections: `[package]` (name, version, target), `[build]`
(entry, out, optimize), `[test]` (include). Defaults apply for
optional keys (target → `vm`, out → `out/`, optimize → `debug`).

`parseWithDiagnostic` surfaces the first error as a typed
`Diagnostic { line, col, message }` so future CLI consumers can
render it with the same caret style other gero diagnostics use.
Multi-error recovery is single-shot in v1 — knit-style can land
later if the manifest grows.

No CLI surface yet: this is library infrastructure; `gero new`
(#134) consumes it.
