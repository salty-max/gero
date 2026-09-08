---
bump: minor
---

feat(lang): `cond and x or y` is the conditional expression

Lua's ternary spelling, as a single three-operand form rather than two
value-returning operators. It desugars in the parser to the `if`
expression (§4.4.2) it means, so `and` and `or` keep their boolean
semantics everywhere else and nothing about the type system changes:

```
let speed = boosted and 20 or 10
let tier  = score > 90 and 3 or score > 50 and 2 or 1
```

Chains nest to the right, so an `elif` ladder fits on a line. Only the
complete three-part shape is a conditional — `a and b`, `a or b`, and
`a and b and c` are unchanged.

**One shape needs parentheses.** A bare `a and b or c` over three
`bool` values reads as the conditional and as `(a and b) or c`, and
the two disagree whenever `a` holds and `b` does not. Rather than pick
silently, the checker rejects it (`E_TYPE_TERNARY_BOOL`) and names both
remedies. One line in the repo needed the parentheses.

Because the branches must share a type, Lua's `cond and false or y`
trap does not carry over: it either types as a `bool` conditional and
is caught by that rule, or does not type at all.
