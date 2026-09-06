---
bump: patch
---

`v.pop()` compiles in statement position. It lowered only as an
expression, so discarding the result — the natural way to use a `Vec`
as a pool — failed with `E_CODEGEN_UNSUPPORTED` even though §3.4.3
documents the method.

A discarded pop drops the last element without materializing the `T?`
it would otherwise return; popping an empty `Vec` is a no-op, matching
the `nil` the expression form gives. That makes push/pop cycling reuse
one allocation, which is the pooling pattern §5.4 points carts toward
in a language whose heap never reclaims.

A test now compiles a program exercising every stdlib and `Vec` call the
spec documents, and names the offending entry if one stops lowering.
