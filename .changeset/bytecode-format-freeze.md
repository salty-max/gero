---
bump: minor
---

docs: the bytecode format is frozen at 0.4

The README's Compatibility section covered the Zig version, the absence
of runtime dependencies, and the cross-target matrix — nothing about
the bytecode, which is the thing downstream consumers actually depend
on. gtx-16, gero-lab and anyone embedding the VM had no stated promise
about whether a `.gx` they built keeps running.

**Within a format major, a `.gx` runs on any gero that accepts that
major** — an older file on a newer build, and a newer file on an older
one, because every minor bump is additive by rule. A higher major is
refused with the version in the message rather than run and hoped for.

`docs/versioning.md` §6 states the guarantee once, covers what format
major 0 does and does not mean, and names what enforces the freeze
rather than merely intending it: the golden corpus fails CI when
emitted bytes move, `gx.version` is the single source of truth the
loader reads from, and the ISA audit left no under-specified corner for
a later reading to disagree about.

The behaviour was verified, not asserted: a `0.9` file runs on a `0.4`
build, a `0.1` file runs on it, and a `1.4` file is refused.
