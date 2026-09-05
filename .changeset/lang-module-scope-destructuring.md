---
bump: minor
---

A destructuring `let` at module scope now works. §7.1 lists `let`
among the declarations a module body may hold, but only the
single-identifier form was lowered — a pattern bound nothing, and
every later reference failed with `E_CODEGEN_UNSUPPORTED: ident not
in current frame`, pointed at the *use* rather than the declaration:

```gero
let (a, b) = (3, 4)

def main()
  print a          -- was: ident not in current frame
  print b
end
```

Every irrefutable pattern form is covered — tuple, struct, wildcard,
and nesting of those — with each bound name getting its own global,
seeded at entry startup in declaration order alongside the other
top-level initializers.

Sizing those globals needed each binder's type, which codegen had no
way to ask for: `CheckedProgram` exposed `expr_types`, and a
destructured binder has no expression of its own. It now also carries
`binder_types`, mapping a binding's declaring identifier to its type.
