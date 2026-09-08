---
bump: minor
---

feat(lang): `if` produces a value

`if` in expression position had an AST node, a doc comment describing
it, and a parser that built it — then codegen rejected it with
`E_CODEGEN_UNSUPPORTED`. The form was reachable from source and no
working program could contain it.

It now lowers. An `if` chain used as a value evaluates to the branch
it takes, the same rule `do … end` follows (§4.3):

```
let label = if hp <= 0
  "dead"
elif hp < 20
  "hurt"
else
  "ok"
end
```

Two checks make that total: an `else` is required
(`E_TYPE_IF_EXPR_NO_ELSE`), and every branch produces the same type
(`E_TYPE_IF_EXPR_BRANCH_MISMATCH`). A branch ending in a statement
types as `nil` and so fails the second, which catches a body that
forgot its value.

Branches are blocks, so they may run statements before their value,
and they may produce aggregates — tuples, structs and arrays each
materialize into the destination through the shared branch skeleton.
A trailing `if` chain is a value block's tail, exactly as a trailing
`do … end` already was.

`if` at statement position is unchanged: no `else` needed, branches
produce nothing.
