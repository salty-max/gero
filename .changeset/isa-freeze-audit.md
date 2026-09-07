---
bump: minor
---

fix(vm,lang): widen the interrupt vector table to all 256 vectors

`int` takes an `Imm8`, so every byte is a legal vector — but the table
was documented as 64 entries in a 256-byte region while the VM
addressed all 256. Vectors above `0x7F` read their handler out of
`0x1100`+, which is where gero-lang loads code, so `int $80` jumped to
whatever the program's own first bytes decoded as.

The table now spans `0x1000..0x11FF` with one slot per vector, and
user RAM starts at `0x1200`. `@interrupt N` outside `0..255` is a
diagnostic (`E_CODEGEN_BAD_INTERRUPT_VECTOR`) rather than a silent
wrap into range.

Two more contract defects the freeze audit turned up, both fixed:

- Reserved `flg` bits (5–15) are masked on write, so they read as `0`
  as ISA §2.1 always claimed. They previously stored whatever was
  written, which would let a program depend on bits a later version
  assigns.
- The `0x00-0x0F` opcode page is documented as permanently unassigned
  and distinct from the `0xD0-0xEF` reserved range: zeroed memory must
  fault rather than execute, so nothing may ever be assigned there.
