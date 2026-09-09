---
bump: patch
---

feat(wasm): `gero_disasm` can emit the hex byte column

`disasm.PrintOptions` has `show_bytes` — the column `gero disasm
--show-bytes` prints between the address and the instruction — and the
export took no flag for it, so a browser host could not ask.

A host cannot reconstruct it either, which is why this has to come from
the module rather than from the caller. The gutter carries **CPU
addresses**, not offsets into the `.gx` the host is holding: slicing
`image[addr..next]` reads the file header, not the instruction. The
lab's disassembly pane showed `47 45 52 4F` — `GERO` — when it tried.

`gero_disasm` takes a fourth argument. §2 of the lab spec records it.
