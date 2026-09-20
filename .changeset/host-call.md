---
bump: minor
---

`VM.call` runs a function in a loaded program and hands control back
when it returns, for a host driving a program's functions itself — a
console calling a cart's per-frame entry points, a debugger
evaluating a call. It enters the way `call Addr` does, restores `sp`
and `fp` on every path, and takes an instruction budget, because a
host calling into a program it did not write should report a runaway
rather than hang on one. `disasm.Symbols.addressOf` is the reverse of
`lookup`, for finding that function by name.
