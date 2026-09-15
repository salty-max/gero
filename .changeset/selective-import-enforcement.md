---
bump: major
---

A selective `use` from a project file binds only the names it lists.

`use Vec2 from "./lib"` brought in the whole of `lib` — every export
was in scope, and a name the target never declared was accepted
without complaint. The item list only mattered for `as` renames, which
added a second name rather than replacing the first. The stdlib form
always behaved as specified; quoted paths did not, because a
quoted-path `use` is resolved as text by the fuse layer and never
reached the checker as a declaration.

The names now travel on the import edge, and the link step binds those
alone. A rename binds the new name only. A name the target does not
export — missing, renamed, or `local` — is `E_USE_UNDEFINED_MEMBER`,
reported at the `use` rather than at whatever line happened to name it.

This is a breaking change: a program that relied on reaching a name it
never imported no longer compiles. The fix is to list the name, or to
use the whole-module form. Nothing in the example corpus relied on it.

`W_UNUSED_IMPORT` covers these imports as a result.
