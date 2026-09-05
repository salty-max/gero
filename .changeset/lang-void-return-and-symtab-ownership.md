---
bump: major
---

Returning a value from a function with no return type is now a compile
error. §4.6 documents `def greet(who: str)` as a **void return**, but
`checkReturn` skipped its compatibility check whenever the enclosing
signature had no `-> T`, so the value was accepted and came back as an
untyped word. With a `str` that meant `print` rendered the interned
pool pointer as an integer:

```gero
def greet()
  return "from a def"
end

print greet()      -- 4478
```

It now reports `E_TYPE_RETURN_FROM_VOID`, pointing at the fix: add
`-> T` to the signature, or drop the value. A bare `return` in a void
function stays legal, and lambdas are unaffected — they infer their
return type from the body.

**Breaking:** a program that returned a value from an unannotated `def`
stops compiling. The value was unusable, so the fix is to annotate the
signature.

Also settles `SymbolTable.putOwned`'s ownership contract, which said
"on error, the caller is responsible for freeing the key" while only
one of its three exits behaved that way. Once the key was registered, a
later failure left it owned by the table, so a caller following the
documentation would double-free. It now takes ownership on every path
except `error.Duplicate`, which is decided before the transfer, and
says so.
