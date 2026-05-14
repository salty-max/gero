---
bump: minor
---

`gero new <name>` + `gero init` — scaffold a minimal v0.2 asm
project from an in-binary template. Two-verb split (cargo / zig /
poetry convention): `new` creates a fresh sub-directory, `init`
initializes the current one. Layout:

```
<name>/
├── gero.toml              # name, version 0.1.0, vm target, entry src/main.gas
├── src/main.gas           # hello-world, halts clean
├── tests/smoke.gas        # template golden-file test
├── tests/smoke.expected   # paired expected stdout ("ok\n")
└── README.md              # build / test / run pointers + tooling.md link
```

Templates are bundled via `@embedFile` — no network call, no
external assets. The `{name}` placeholder substitutes into
`gero.toml` and `README.md`; pure-asset templates (`main.gas`,
`smoke.gas`, `smoke.expected`) round-trip verbatim.

Philosophy: guide, don't force. The scaffold ships no CI /
pre-commit config — that choice is the user's. The scaffolded
README links to the upstream tooling guide where copy-paste
recipes for GitHub Actions, GitLab, lefthook, and plain git
hooks land in #126.

Name validation rejects empty, > 64-char, leading-digit /
leading-dash, and shell-metacharacter names. Pre-existing target
directory yields a clean "already exists" error (exit 1) rather
than overwriting.

`gero init` (no positional args) scaffolds into the cwd — the
basename becomes the project name. Pre-flights every target path
and refuses to overwrite if `gero.toml`, `src/main.gas`,
`tests/smoke.gas`, `tests/smoke.expected`, or `README.md`
already exist. `gero new .` is rejected with a redirect to
`gero init` rather than silently doing in-place magic.

Both subcommands share the embedded templates + `scaffold()`
primitive in `new.zig`; `init.zig` is the thin in-place wrapper.

Builds on top of the `gero.toml` parser from the previous patch
(#133). `gero build` / project-aware `check`/`fmt`/`test` consume
the same manifest shape in their own sub-issues.
