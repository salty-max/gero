---
bump: patch
---

fix(lang): drop the hidden sret pointer for every call that pushes one

A call returning a struct, tuple, scalar optional or fixed array is
passed a hidden pointer to the caller's return buffer. The push covered
all four; the matching stack cleanup counted only structs and tuples,
so every array-returning and scalar-optional-returning call left 2
bytes on the stack.

The drift is invisible while nothing reads `sp` across the call, which
is why it went unnoticed. It is not invisible to a comparison that
parks one operand in an `sp`-relative slot and then evaluates the
other: `mk(1) == mk(1)` copied the second result over the first and
reported them unequal. That comparison now answers correctly, and the
guard rejecting two call operands is gone.
