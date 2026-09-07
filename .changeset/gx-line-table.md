---
bump: minor
---

feat(asm,lang): a source line table in the `.gx` debug section

The debug section carried symbols only, which is enough to label a
disassembly but not to map a machine address back to a source
position. `.gx` now also carries a files chunk and a line table —
`address range → (file, line, column)` — emitted by both front-ends
when a build has an include / import map to attribute files with.

This is what a source-level debugger needs: stepping by line, a
current-line highlight, and setting a breakpoint by clicking a line
rather than typing an address.

Ranges are explicit rather than implied by the next row's start, so an
address in a gap resolves to no row instead of silently borrowing the
previous statement's position. Rows nest wherever statements do;
`gx.lineAt` resolves an address to the innermost one.

Release builds are unaffected — no debug symbols, no line table, and
the image is byte-identical either way.

`gero info` reports the table's size, and cached fragments carry their
rows, so a warm build's debug section matches a cold build's.
