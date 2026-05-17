---
bump: minor
---

VM bump allocator — shared infrastructure for M3b's class instances
and closure heap-cells.

**ISA changes (version 0x0001 → 0x0002):**

- `.gx` header bytes `0x0E..0x0F` (previously "reserved, must be 0")
  now carry `heap_base: u16` — the address where the bump allocator
  starts. `0x0000` means the program declared no heap and `sys alloc`
  will fault on first call. Old `0x0001` files always read `0x0000`
  here and load fine; they just can't allocate.
- New fault vector `0x04` — `heap_exhausted`. Raised when `sys alloc`
  can't satisfy a request (cursor would collide with the stack,
  overflow the 16-bit address space, or `heap_base = 0`).
- New `sys` syscall `0x20` — `alloc`. Reads requested size in bytes
  from `acu`. On success: returns the freshly-allocated address in
  `acu` and advances the VM's heap cursor by the requested size. On
  exhaustion: raises the `heap_exhausted` fault.

**Codegen:**

- `.gx` header emission writes `heap_base = data_cursor` at the end
  of emission, so the heap starts at the first byte past the static-
  data region and grows upward toward the stack.
- `gero.lang.internal.codegen.opcodes.Sys.alloc = 0x20` constant
  added — internal seam for future PRs (classes #260, closures #259)
  to emit `mov size, acu; sys 0x20` at allocation sites.

**Out of scope:**

- User-facing language API for raw allocation (no `mem.alloc`
  builtin in this PR — the allocator is infra-only). Classes and
  closures will consume it from the codegen side; if a user-facing
  raw-alloc surface emerges later, it lands as its own design.
- Free / GC. The bump allocator only grows. A program that exhausts
  its heap region faults; restarting the VM resets the cursor.
- Per-bank or per-region heap (the bump cursor is global).
