---
bump: minor
---

feat(wasm): toolchain exports over a virtual file set

`gero.wasm` now compiles, assembles, checks, formats, and disassembles
— all against a named set of source buffers rather than a filesystem.
A multi-file program with `use` or `include` builds in a browser
exactly as it does on disk.

Both resolvers gained a `Source`: the host filesystem (with the
overlay an editor uses for unsaved buffers), or a set that **is** the
filesystem. In the second, a name the set does not hold is a
not-found diagnostic rather than a read — which is what makes
resolution closed, so a `use` cannot reach outside what the caller
supplied.

Verified against the CLI rather than assumed: `gero_format` is
byte-identical to `gero fmt --stdin`, and `gero_check`'s diagnostics
match `gero check --format=json` field for field.
