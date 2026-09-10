---
bump: major
---

The bytecode format is frozen at **1.0**.

The major bump is owed to the memory-map change that preceded it: the
bank window, the IO page and the boot stack all moved, and none of that
is encoded in a `.gx` header. A `0.x` archive is well-formed — its
instructions simply address a machine that no longer exists, writing
`$C000` for a bank window that is now plain RAM, or reading a stack
where it used to boot. Accepted and silently wrong is the one outcome
the version field exists to prevent.

So the loader refuses **any** other major now, in either direction,
naming both versions rather than only a ceiling. A higher major means
rules this build does not know; a lower one means rules it no longer
follows.

From here, a change that would make a VM accept a file and do the wrong
thing requires a major bump, and a major bump is a deliberate,
documented event. The promise is about what a `.gx` means and does not
wait on any package version — `gero` is at `0.2.0` and the format is at
`1.0`.
