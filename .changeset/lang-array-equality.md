---
bump: minor
---

fix(lang): arrays compare by element, not by address

`==` on two arrays compared their base addresses, so identical
contents compared unequal with no diagnostic:

```
let a: [u8; 2] = [1, 2]
let b: [u8; 2] = [1, 2]
a == b        -- was false
a == a        -- was true
```

Arrays had no equality path at all and fell through to the scalar
`cmp`, which sees the two base pointers. They now compare their packed
elements, matching structs, tuples and `str`, all of which already
compared by value. §6's structural-equality note covers arrays and
tuples explicitly.

Both operands are materialized as distinct stack copies before the
comparison, so an operand that returns through the call buffer does
not alias the other.

A `struct` with a tuple field also compares correctly now — it
previously raised `E_CODEGEN_UNSUPPORTED`, because a field wider than
a register was compared as its first word only.

Two cases still raise a diagnostic rather than answer:

- An array whose elements need content comparison (`str`, nullable,
  `Vec`, payload-carrying enum), which a packed-byte compare would get
  wrong.
- `==` where **both** operands are calls: the second call's return
  buffer lands on the first result. Bind one to a `let` first. A struct
  comparison of the same shape works, so there is a model to follow.

A `struct` with an **array** field keeps its existing
`E_CODEGEN_UNSUPPORTED` — such a struct does not copy the array's
bytes when it is materialized, so accepting the comparison would have
answered "equal" for every input.
