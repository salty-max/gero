---
bump: minor
---

`gero build` — project-aware compile. Walks the ancestor chain
for `gero.toml`, reads `[package]` + `[build]` from the manifest,
runs the asm pipeline against `build.entry`, and writes the
resulting `.gx` to `<project_root>/<build.out>/<package.name>.gx`.

Closes the loop for the v0.2 "100% gero project" experience:

```bash
gero new my-cart && cd my-cart && gero build && gero run out/my-cart.gx
```

Output filename comes from `[package].name`, not the entry's
basename — the manifest is the single source of truth. `out/` is
created if missing.

Resolves the manifest by ancestor walk, so `gero build` works
from any subdirectory of the project. Manifest-relative
`build.entry` / `build.out` are joined under
`dirname(gero.toml)`.

`--target=<vm|gtx-16>` overrides the manifest's
`[package].target`. Only `vm` ships in v0.2; `gtx-16` errors with
a clear "not yet implemented" diagnostic.

Reuses the same `resolveIncludes` → `parse` → `assemble` pipeline
as `gero asm`, with the same `✓ <path> (N bytes, M banks)` + footer
shape and the same exit codes (`0` ok, `1` host IO, `2` usage,
`3` parse / asm error).

Per-phase `--verbose` timings mirror `gero asm`: include / parse
/ codegen / write.
