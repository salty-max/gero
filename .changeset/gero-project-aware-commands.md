---
bump: minor
---

`gero check` / `gero fmt` / `gero test` — project-aware fallback.

Invoked with no positional args inside a gero project (cwd or
any ancestor has `gero.toml`), each command resolves its target
file list from the manifest:

- **`gero check`** — walks `[build].entry` + every entry in
  `[test].include` so the whole project type-checks in one pass
- **`gero fmt` / `gero fmt --check`** — same shape, formats or
  diff-checks the same union
- **`gero test`** — walks `[test].include` for `.gas` programs
  paired with sibling `.expected`. The previous hardcoded
  `tests/asm/` root is gone — `gero test` is now binary-portable
  to user projects

No manifest + no positional args → exit 2 with a usage hint
("missing source file or directory path (or run inside a gero
project)"). `gero test` outside any project always errors —
there's no sensible default root for a CLI shipped as a binary.

Explicit positional args keep their current single-file /
directory-walk semantics — no behavior change for existing
invocations.

Shared manifest-loading + include-expansion logic lives in
`apps/gero-cli/manifest_loader.zig` (load + parse-error
reporting + file-or-directory expansion). `project.zig` stays
the pure-parser module.

Template scaffolds re-canonicalized so `gero fmt --check`
reports zero drift on a freshly-scaffolded project.
