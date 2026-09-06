---
bump: patch
---

Six CLI modules held inline tests that never ran. `apps/` keeps its
tests in the source file rather than a `tests/` mirror, and a module
has to be registered as a test root in `build.zig` for those to
execute — `bench`, `gr_runner`, `build_cache`, `compile`, `repl` and
`line_editor` were not.

Registering them turned up **58 tests that had never executed**, five of
them broken:

- `gr_runner`'s discovery test did not compile — it built a `Term` with
  a field the type does not have.
- Two `line_editor` tests crashed. They passed `undefined` for the `io`
  parameter, which `Editor.init` dereferences to probe stdin for a TTY.
- Three `repl` tests asserted on `if x do … end` and a single-line
  `bake do … end`, neither of which is valid gero-lang — a `do` block
  spans lines and `if` takes no `do`.

A lint rule now fails the build when an `apps/` module with a `test`
block is missing from `build.zig`.
