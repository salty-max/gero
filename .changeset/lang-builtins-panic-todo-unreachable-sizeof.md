---
bump: minor
---

Four new always-in-scope builtins fill gaps the spec already
referred to but didn't define:

- `panic(msg: str) -> noreturn` — uniform "halt with a message"
  intent. Replaces the per-program `@noreturn def panic ...`
  boilerplate.
- `unreachable() -> noreturn` — prints `"unreachable code
  reached"` then halts. Marks compiler-provable-dead branches
  (exhaustive `match` fallthroughs, post-validation arms).
- `todo(msg: str?) -> noreturn` — Rust-style scaffold for
  incremental development. Prints `TODO` or `TODO: <msg>` then
  halts.
- `sizeof(T) -> u16` — compile-time byte width of a type. Folds
  to a `u16` literal at codegen. Works on every type form
  (primitives, arrays, tuples, named structs, classes). Spec
  text §3.2 / §3.4 already used `sizeof(T)` informally — now
  formalized.

`sizeof` is a new keyword (`kw_sizeof`) because the arg slot is
a type annotation, not an expression. The other three resolve
before regular callee resolution like `assert` / `debug_assert`.

User declarations matching the builtin names (`assert`,
`debug_assert`, `panic`, `unreachable`, `todo`) emit
`E_BUILTIN_SHADOW`. `sizeof` is a keyword and rejected by the
parser before this check ever runs.

Closes #295.
