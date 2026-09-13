---
bump: minor
---

`zig build docs` generates the public API reference.

Every public declaration already carries a `///` comment — the linter
refuses one that does not — and nothing turned them into something a
consumer could read without opening the source. `zig build docs` emits
Zig's own autodoc into `zig-out/docs/api`, so the reference is
generated from the declarations rather than maintained beside them and
cannot drift from what it documents.

It runs in `ci`, which proves the comments still parse. The linter
proves they exist; together that is a reference which is both complete
and correct by construction.
