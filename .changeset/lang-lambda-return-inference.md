---
bump: patch
---

A lambda with no return-type annotation now infers its return type
from the body. Previously the type came only from an explicit `-> T`
or from a function-typed binding hint; with neither, it fell back to
`nil`, so a lambda returning a `str` lost that type and `print`
rendered the interned pool pointer as an integer:

```gero
let a = || -> str "hi"
print a()                 -- hi
let b = || "hi"
print b()                 -- 4589
```

Integer and bool bodies appeared to work only because a word-sized
`nil` slot prints the same way an `i16` does.

Inference covers both lambda forms and any body shape — short
(`|| "hi"`), long (`lambda () return "hi" end`), and a `do … end`
value block — since all three desugar to `return` statements. An
explicit annotation still wins, and a function-typed hint still wins
over the body, so `let f: fn() -> str = || "hi"` is unchanged.

A body whose `return`s disagree is now rejected with
`E_TYPE_MISMATCH` against the first one, instead of silently taking
whichever came first. A body with no value-returning `return` stays
`nil`.
