---
bump: minor
---

`gero.toml` polish — extends every section with low-cost, high-leverage
config that was sitting in TBD column:

**`[package]` metadata** (all optional, no behavior today but
parser-ready for a future registry / doc generator)

```toml
[package]
description = "..."
license = "MIT"
repository = "https://github.com/..."
authors = ["Jane Doe <jane@..>"]
keywords = ["vm", "demo"]
```

**`[build]` — decouple binary name, strip debug symbols, per-profile output**

```toml
[build]
name = "cart-cli"         # output filename stem; default = package.name
debug_symbols = false     # strip debug blob; default true
```

Output path is now `<build.out>/<build.optimize>/<stem>.gx` —
Cargo's `target/{debug,release}/` pattern. Rebuilding in release
no longer clobbers the debug artifact; both coexist
side by side. `<stem>` is `[build].name` if set, else
`[package].name` (Cargo's `[[bin]].name` convention).
`debug_symbols = false` shaves the `(address, name)` table out
of the `.gx` for release builds.

`[build].optimize` is validated against `{debug, release, size}`
at parse time so a typo doesn't silently land artifacts in
`out/relase/`. Invalid → clean diagnostic with line:col.

**`[test]` — exclude + cycle budget**

```toml
[test]
exclude = ["tests/wip"]     # subtract paths (file or dir prefix)
cycle_budget = 5_000_000    # per-test cycle cap; default 1M
```

Exclude matches as a directory prefix (`tests/wip` excludes
`tests/wip/foo.gas` and `tests/wip/sub/bar.gas`) or as an exact
`.gas` path. The previously-hardcoded 1M cycle budget is now a
manifest knob.

**TOML parser**: integer literals accept underscore separators
(`1_000_000`) so the cycle-budget shape matches what users
already write in TOML. Boolean values added under `[build]`
(was `[fmt]`-only).

Wired into `gero build` (uses `build.name` + `build.debug_symbols`
when assembling) and `gero test` (uses `test.cycle_budget` +
filters out `test.exclude` paths). `gero check` / `gero fmt` keep
walking the full `[test].include` (exclude only narrows the test
set, not the lint set — gives users a knob to keep WIP code
under fmt/check while skipping it in `gero test`).
