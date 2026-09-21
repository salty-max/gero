---
bump: patch
---

Calling an `@inline` def that has a default parameter more than once
produced the wrong value at the second call site — silently, and with a
plausible-looking number. Each call was correct in isolation, which is
what kept it hidden.

The caller's prologue reserves the frame that every inline expansion
splices into, and the expander binds one slot per parameter: a call that
leaves a trailing default out still has it filled in first. The
reservation, though, counted the arguments the call wrote. A call short
of its arity therefore reserved nothing for the default, and the next
expansion's slots landed on live stack — in the case that surfaced it,
on an argument the body had just pushed, so a parameter read back as the
address of the register being written. The count now follows the
parameter list, and a variadic call that runs past it still counts every
argument.
