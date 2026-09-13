---
bump: minor
---

`gero run` restores a program's saved data at boot.

Battery-backed banks were written to a `.sav` beside the `.gx` on
`int $21` and never read back, so SRAM did not survive a run. A cart
that saved and reloaded appeared to work — the file was there, with
the right bytes in it — and then started from nothing every time.

`isa.md` §3.2.1 has always said the host loads SRAM banks at boot if a
save exists, and `examples/asm/save.gas` told the reader that
re-running picks the save back up. Both describe what now happens.

A save whose size does not match the program's SRAM is refused with a
message rather than restored as far as it goes: SRAM is the program's
own state, and half of a save is worse than none of it. A missing save
is not an error — that is the first run, and the banks stay zeroed.
