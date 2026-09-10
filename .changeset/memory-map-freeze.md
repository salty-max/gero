---
bump: major
---

The memory map is laid out so every region can do its job.

**The bank window is exactly one bank.** It was `0xC000..0xFEFF` —
16128 bytes against a 16384-byte bank — so 256 bytes of every bank were
unreachable and rode along in every `.sav`. It is `0xBE00..0xFDFF` now,
exactly `bank_size`, and every byte of a bank is addressable.

**The IO page is 512 bytes and sits above the window**
(`0xFE00..0xFFFF`). It was 256 bytes at the very top, which put the
window against it — and gtx-16's registers, which start at `0xFE00`,
inside the *bank window*. A cart that switched banks would have swapped
its own display, audio and input registers out of existence. Every
gtx-16 register keeps its documented address; the region around them
moved.

**`sp` and `fp` boot at `0x7FFE`**, the top of user RAM, not `0xFFFE`.
The old value put the first `push` inside the IO page and, 127 pushes
later, inside the bank window. Three constraints meet at the new one:
flat memory, above the heap (`sys alloc` refuses to grow past `sp`),
and room to descend.

**A banked program may not reach into the window with its base image**
either — `ImageInBankWindow`, on the same ground the loader already
refused `heap_base` there.

Programs that hard-code the old window or stack addresses must move.
Nothing about the instruction encoding or the `.gx` header changed.
