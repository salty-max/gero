---
bump: patch
---

The VM runs about 100× faster.

`Memory` holds its 64 KB address space as an inline array, and
`Memory.readByte`, `MemoryMapper.readByte` and their word forms all
took `self` **by value** — so every byte the VM read copied the whole
address space first. An instruction reads its opcode and operands, so
a single instruction moved a quarter of a megabyte before doing any
work, and a profile of a running program was almost entirely
`memmove`.

Those receivers are pointers now. On a 524,290-instruction loop the
same image goes from 0.18 to 17.7 million instructions per second,
measured `ReleaseFast` on the same machine.

Nothing about behaviour changes — the same programs produce the same
cycle counts and the same bytes, which is what made the fix safe to
make and easy to check.
