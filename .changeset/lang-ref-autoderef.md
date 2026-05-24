---
bump: minor
---

`&T` references now auto-deref for field access and method
dispatch per spec §3.4.4. Given `r: &Counter`, both `r.n` and
`r.method()` resolve through the pointee's class layout / vtable
— the typechecker peels one reference layer before field /
method resolution, and the codegen emits an extra word-load
through the reference slot to reach the heap-allocated instance.
Mutation through a `&T` parameter (`r.n = r.n + 10`) writes
back to the caller's binding. Closes #216.
