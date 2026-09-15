---
bump: patch
---

A diagnostic about a `use` line points at the word that is wrong.

`E_USE_UNDEFINED_MEMBER` and `E_USE_DUPLICATE_ALIAS` both rendered a
single caret at column 1, whatever the directive said:

```
use Vec2, Missing, Other from "./vec"
^
```

A quoted-path `use` never reaches the parser — the fuse layer resolves
it and blanks the line — and it was blanked to a single byte, so the
only offset a diagnostic could hold was the start of the directive.
The near-spelling `help:` line existed to carry the name the caret
could not reach.

The line is now blanked to its own width instead. Every column keeps a
fused offset that maps back through the source map, the parser still
sees whitespace, and the caret lands on the name:

```
use Vec2, Missing, Other from "./vec"
          ^^^^^^^
```

Emitted bytecode is unchanged — the golden corpus matches byte for
byte.
