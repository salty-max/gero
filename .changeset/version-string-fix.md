---
bump: patch
---

`gero --version` now reflects the actual package version. Previously
`apps/gero-cli/cli.zig` held a hard-coded `version_string = "0.0.0"`
that `zig build version` didn't touch, so every shipped binary —
including v0.1.0 and v0.1.1 — printed `gero 0.0.0` regardless of the
release tag. `build.zig` now reads `build.zig.zon`'s `.version` field
and injects it into the CLI via the `build_options` module, making
`build.zig.zon` the single source of truth.
