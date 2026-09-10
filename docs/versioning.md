# Bytecode versioning

[`isa.md` §10](isa.md) states the rule: additive changes bump the
minor, breaking ones bump the major. This document says which concrete
edits land on which side, so the question is settled before a change
is written rather than argued after.

Every example here is a change this repository actually made.

---

## 1. Two version numbers

They are unrelated, and conflating them is the first mistake to avoid.

| | Where | Means |
|---|---|---|
| **Package version** | `build.zig.zon` (`0.2.0` today) | The Zig package. Follows normal semver for the *library API* — `gero.vm.step`, `gero.lang.compile`, and so on. |
| **Format version** | `.gx` header bytes `0x04..0x05` (`0x0100` today) | The bytecode container and the ISA it encodes. High byte major, low byte minor. |

A release can bump one and not the other. Renaming a public Zig
function is a package break and no format change at all; adding an
opcode is a format change that may not touch the library's surface.

The format version has exactly one source of truth in the code —
`gx.version` — and `loader.version_target` reads from it. They were
briefly two constants and drifted: producers moved to `0x0004` while
the loader still claimed `0x0003`. The major-only check hid it.

---

## 2. What the format version governs

**A `.gx`'s version field is a promise about execution**: a VM
accepting a file must be able to run it correctly.

The loader compares **major only** — a higher minor is accepted, a
higher major is refused. That is what makes the additive/breaking
split meaningful: an older VM must either run a newer file correctly
or refuse it, and never run it wrongly.

Metadata a VM ignores — the debug section — is held to a weaker but
still real standard: a change there is additive **only if an older
reader detects it** rather than silently misreading. See §3.

---

## 3. Additive — bump the minor

An older VM either runs the file correctly or refuses it outright.

**A new field in reserved header space.** `0x0002` added `heap_base`
at offset `0x0E`, which `0x0001` had specified as reserved-and-zero.
Files declaring `0x0001` read `0x0000` there, which means "no heap" —
so an older producer's files keep their exact meaning.

**A new opcode in an unassigned slot.** `0x0003` added `muls`, used by
gero-lang's debug overflow trap on `*`. An older VM meeting `muls`
raises the invalid-opcode fault (§5) — it refuses loudly rather than
mis-decoding. That fault behavior for unassigned opcodes is *why* this
is additive, and it is why `0x00-0x0F` and `0xD0-0xEF` must keep
faulting.

**A detectable change to the debug section.** `0x0004` reframed the
debug section as `[kind][len][payload]` chunks. The VM never reads it,
so execution is unaffected. An older `parseSymbols` meeting the new
framing reads a nonsense symbol count and runs off the end of the
payload — returning `TruncatedSymbolSection`, not wrong symbols.

That distinction is the whole test. Had the old reader silently
produced plausible-but-wrong symbol names, this would have been a
major bump: a debugger showing the wrong function for an address is
worse than one that refuses to show any.

**A new reserved-vector assignment**, a **new syscall number**, and a
**new debug chunk kind** are additive for the same reason — the ISA
requires readers to fault on unassigned opcodes, and to *skip* unknown
chunk kinds (§7.3).

---

## 4. Breaking — bump the major

An older VM would accept the file and do the wrong thing.

**Changing an existing opcode's semantics, operand shape, or size.**
No instance yet; the opcode table has only grown.

**Renumbering registers or vectors.** Never done. It would silently
redirect every existing program's register operands.

**Repurposing a reserved bit that readers silently ignore.** Whether
this is breaking depends entirely on what a reader does with the bit
today, and gero has one of each:

- `flg` bits 5–15 are **masked off on write** and read as `0`. Assign
  bit 5 a meaning and an older VM clears it — accepting the program
  and running it with the new flag's effect silently dropped. That is
  the definition of breaking, so it needs a **major** bump.
- The header's flag bits `2-15` are **rejected**: a file with any of
  them set fails to load. Assign one and an older VM refuses the file
  instead of misrunning it, so that is **minor**.

The lesson generalizes: reserve by rejecting, not by ignoring. A field
readers ignore can only be assigned with a major bump; one they reject
can be assigned any time.

**Moving a header field or changing its width.**

**Tightening a validity rule.** This is the one that looks additive
and is not.

`heap_base` carried the wording "usually the first byte past the end
of static data" — advice, not a constraint. It is now a rule: at or
above `image_size`, and below the bank window in a banked program.
Files violating it are rejected.

That was safe as a minor bump **only because no image in existence
violated it** — the compiler computed a legal value and the assembler
wrote `0`. Make the same edit after files exist in the wild and it
rejects programs that already work, which is a major break however
correct the new rule is.

So: tightening is additive only when you can show the tightened rule
was already true of every file. Otherwise it is major.

---

## 5. Neither — no format bump

**Fixing an implementation to match the spec.** Reserved `flg` bits
5–15 stored whatever was written, though §2.1 always said they read as
`0`. Masking them on write is observably different, and a program that
kept data there stops working — but that program was relying on
behavior the spec never offered. The contract did not change; the
implementation started honoring it.

The test is whether the *spec* changed. If the documented behavior is
the same before and after, no format bump — however visible the fix.

**Changing a documented region the VM does not enforce.** Widening the
interrupt vector table moved user RAM from `0x1100` to `0x1200`. No
existing image broke: the VM never enforced the boundary, and no
program used a vector above `0x3F`. Had the VM rejected images with
code below `0x1200`, the same edit would have been major.

**Clarifying prose, fixing a typo, documenting behavior that was
already implemented and observable.**

---

## 6. The compatibility guarantee

The rules above exist to support one promise, stated here once so
README and the changelog can point at it rather than restate it.

**Within a format major, a `.gx` runs on any gero that accepts that
major.** Both directions hold, and they are not the same claim:

| | Behaviour | Why |
|---|---|---|
| Older minor, newer gero, same major | Runs | Nothing was removed; §4 is what a removal would require. |
| Newer minor, older gero, same major | Runs | Every minor bump is additive (§3), so the older VM either handles the addition or ignores metadata it can detect. |
| **Any other major**, either direction | **Refused**, with both versions in the message | §4 changes meaning. A higher major means rules this build does not know; a lower one means rules it no longer follows. Running either would be silently wrong, which is the one outcome the version field exists to prevent. |

The second row is the one worth being precise about: an older VM
**accepts** a same-major newer file. It is not rejected and then
tolerated — it is expected to run correctly, which is exactly the
burden §3 places on every additive change. A change that an older VM
would accept and mishandle is not additive, whatever it looks like.

Verified rather than asserted: a `1.9` file runs on a `1.0` build and a
`1.0` file runs on a `1.9` one, while a `0.4` file is refused with
`built for .gx format 0.4, but this build speaks 1.0 — the majors
differ, so it would not run correctly`.

### Format major 1

The format is at major **1**. It reached it once, for one reason worth
recording because the shape recurs.

Major 0 was never "unstable" — it meant no breaking change had been
needed, and the minor reached 4 through four additive ones. The break
came from the memory map, not the container: the bank window, the IO
page and the boot stack all moved (ISA §3.1, §8), and none of that is
encoded in a `.gx` header. A `0.x` file is a perfectly well-formed
archive whose *instructions* address a machine that no longer exists —
writing `$C000` for the bank window, or reading the stack where it used
to boot.

That is the case §2 is about. The file would be accepted and would run
wrongly, silently, which is exactly what a major bump prevents. It is
also the reminder that the format version is a promise about
**execution**, not about the bytes of the container: a change that
touches neither the header nor an opcode encoding can still break every
program that was built before it.

### The freeze

From format **1.0** onward, the container and the machine it encodes
are frozen in the sense §4 defines: a change that would make a VM
accept a file and do the wrong thing requires a major bump, and a major
bump is a deliberate, documented event rather than a side effect.

This is a promise about the format, and it does not wait on a package
version. `gero` is at `0.2.0` and the format is at `1.0`; §1 explains
why those are different numbers and why neither implies the other.

What enforces it, rather than merely intending it:

- The loader refuses **any** other major, in either direction, naming
  both versions. A file from a machine this build does not implement
  does not run.
- The golden corpus (`zig build golden`) compares emitted bytes against
  a blessed set, so a codegen change that moves bytes fails CI until
  someone says why and re-blesses.
- `gx.version` is the single source of truth and `loader.version_target`
  reads from it — they drifted once, and a major-only check hid it.
- The ISA was audited against the implementation before the freeze, so
  no under-specified corner is left for a later reading to disagree
  about (`docs/isa.md` §11).

What the freeze does **not** promise: that `gero` the tool holds its
CLI, its library API, or its diagnostics steady. Those follow the
package version and its own semver. The freeze is about what a `.gx`
means.

---

## 7. Declaring the bump

A changeset already carries `bump: patch | minor | major` — that is
the **package** version. When a change also moves the format version,
say so in the changeset body and bump `gx.version`.

Ask, in order:

1. Does the documented behavior change at all? No → no format bump.
2. Would an older VM accept the file and behave differently than a
   current one? Yes → **major**.
3. Would an older VM refuse the file, or run it correctly? →
   **minor**.
4. Does it tighten a rule? Then it is minor only if every file that
   could exist already satisfies it. Otherwise **major**.

If steps 2 and 3 are hard to answer, that is usually a sign the change
is not detectable by an older reader — which is itself the answer:
major.
