---
bump: patch
---

fix(wasm): `gero_disasm` returns annotated assembly, and a release carries the browser module

§2 of the gero-lab spec calls `gero_disasm`'s payload annotated
assembly, and §6 builds a debugger pane on it: a click on a line sets a
breakpoint, and the stopped instruction highlights. Both need each line
to carry its address. The export was calling `disasm.writeBytes`, which
emits mnemonics only — a pane could show the text and map none of it.

It now calls `writeBytesPretty` with the image's base address, its
entry marker, and its symbol table, so a branch renders as its label
rather than as `&XXXX`. That matches what `gero disasm` has always
printed; the two views no longer disagree about what a disassembly is.

The disassembly moves from the export surface into `toolchain.zig`,
beside the other operations, leaving the export the pointer decoding it
is meant to be — which is also what lets it be tested.

`bank` of `0` is a real window and never meant the base image; the
sentinel `0xFFFFFFFF` is now `abi.no_bank` rather than a bare constant
next to the one export that reads it.

Releases publish `gero.wasm` and `samples.json` as loose assets. §10
says the module's release carries the sample sources, and nothing did —
a browser host fetches both by URL and cannot unpack a target tarball.
