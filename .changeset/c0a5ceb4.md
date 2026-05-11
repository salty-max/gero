---
bump: minor
---

Add the VM kernel scaffold: `Register` / `Registers` / `Flag` /
`Memory` / `VM` types. 15 named u16 registers indexable by name
or operand index, 64KB linear address space with little-endian
word access, ISA §8 boot-state defaults (`sp`/`fp`=0xFFFE, `mb`=0,
`im`=0xFFFF, `flg`=0). Foundation for the opcode dispatch loop
(next).
