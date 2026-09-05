---
bump: patch
---

`print` on a nullable is now the compile error §4.9 always specified,
instead of emitting a meaningless address. A scalar `T?` printed its
frame-slot offset and a pointer-like `T?` printed its raw pointer:

```gero
let a: i16? = 12
print a              -- -6

let v: Vec(i16) = Vec.new()
v.push(41)
print v.get(0)       -- -24
```

Both now report `E_CODEGEN_UNSUPPORTED` pointing at the unwrap:
`if let x = value` then print `x`. The check covers `$(…)`
interpolation too, since both share one rendering path. Struct
fields and tuple elements of nullable type were already rejected;
this was the top-level value.

The three aggregate rejection messages listed only
`array / Vec / class / reference`, omitting the fn-pointer and
nullable cases §4.9 also names — they now match the spec's list.

Spec drift fixed alongside: §3.4.1 restricted `T?` to pointer-like
types, but scalar optionals ship and `Vec.get` / `Vec.pop` return
them. It now documents both layouts — a pointer-like `T?` is one
word with `$0000` as `nil`, a scalar `T?` is a 4-byte
`{present, value}` since `$0000` is a legal `i16` — and when to
prefer a sentinel. `lang-diagnostics.md` follows: the
`E_NULL_NON_POINTER` row and its worked mockup described `i16?` as
rejected, which stopped being true when scalar optionals landed.
