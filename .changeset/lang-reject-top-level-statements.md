---
bump: major
---

An executable statement at module scope is now a compile error. §7.1
has always said execution begins at `def main()` and the rest of a
module body is declarations — `def` / `class` / `struct` / `enum` /
`const` / `let` / `use` — but codegen silently dropped anything else:

```gero
let g = 7
print "top level"     -- compiled clean, never ran

def main()
  print g
end
```

The statement produced no bytecode and no diagnostic. It now reports
`E_TYPE_TOP_LEVEL_STATEMENT` from the typechecker, so `gero check`
catches it too, naming the construct in source terms and pointing at
`main`.

**Breaking:** a program that relied on the old tolerance stops
compiling. Any such statement was already dead code — it never
executed — so the fix is to move it into `main` or a function `main`
calls.
