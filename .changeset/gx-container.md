---
bump: minor
---

refactor(asm,lang): one `.gx` container implementation

The archive header and layout were written twice — once in the
assembler, once in lang codegen — and had drifted. The assembler
stamped version `0x0001` where ISA §7.1 says the current format, so the
same ISA produced two different headers depending on which front-end
wrote the file.

Both now go through `gero.gx`, which owns the format: magic, version,
header layout, bank windows, and the debug section. That is also the
single place a bytecode-format freeze has to lock.

The debug section becomes a sequence of `[u8 kind][u32le len][payload]`
chunks, with the existing symbol table as chunk `0x01`. A reader skips
a kind it does not know, so a later table can be added without another
format break. Version is now `0x0004`; the loader compares only the
major byte, so existing images keep loading.
