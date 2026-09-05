---
bump: minor
---

`local` now does what §5.1 always said it does. The keyword was
lexed, parsed for every declaration form, and stored on the AST —
and then ignored, so a `local` declaration was freely reachable
from an importing module.

With each module holding its own scope, a `local` declaration
simply stays out of importers' scopes. It still resolves normally
inside its own module. Reaching one across a boundary names the
real reason rather than falling through to "undefined symbol":

```
error: `helper` is declared `local` in `lib.gr` — a `local`
       declaration stays private to its own module (§5.1); drop
       `local` there to export it [E_TYPE_PRIVATE_ACCESS]
```

`@private` on a top-level `def` or `let` is now rejected. §3.7.6
scopes it to class members, but the annotation registry accepted it
anywhere and then ignored it — the same silent acceptance in
reverse. The message points at `local`.
