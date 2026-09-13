# 7. Banking

A sixteen-bit address reaches 65,536 bytes and no more. That is not a limit
the designers could have relaxed; it is arithmetic. Sixteen bits count to
65,535, and an address is sixteen bits.

Yet cartridges for machines like this routinely held several times that. This
chapter is about the trick that makes it possible, and about the price — which
is real, and which shows up as a discipline the program has to keep rather
than as a slower instruction.

## Swapping what an address means

If you cannot have more addresses, the remaining option is to make some
addresses mean different things at different times.

Gero reserves a 16 KB region, `$BE00..$FDFF`, as the **bank window**. A
program's storage is divided into banks of exactly that size, and the `mb`
register selects which one the window currently shows. Writing to `mb` swaps
the contents of those 16 KB for another 16 KB entirely, in one instruction.

So a program with eight banks has 128 KB of storage reachable through a 16 KB
opening, one bank at a time. The address space never grows. What changes is
which bytes answer to `$BE00`.

```asm
const PRINT = $10

main:
  mov $00, mb
  call speak
  mov $01, mb
  call speak
  mov $0A, r1
  int PRINT
  hlt

bank $00
speak:
  mov 'H', r1
  int PRINT
  ret

bank $01
speak_one:
  mov 'i', r1
  int PRINT
  ret
```

```text
Hi
```

Read that program again, because it is stranger than it looks. It calls
`speak` twice and gets two different routines. The disassembly explains why:

```text
; --- base image ---
0000:  10 00 00 0C     mov   $0000, mb  ; entry point
0004:  A0 00 BE        call  speak
0007:  10 01 00 0C     mov   $0001, mb
000B:  A0 00 BE        call  speak
000E:  10 0A 00 02     mov   $000A, r1
0012:  FC 10           int   $10
0014:  FF              hlt

; --- bank 0 ---
BE00:  10 48 00 02     mov   $0048, r1
BE04:  FC 10           int   $10
BE06:  A2              ret

; --- bank 1 ---
BE00:  10 69 00 02     mov   $0069, r1
BE04:  FC 10           int   $10
BE06:  A2              ret
```

Both banks begin at `BE00`. Both calls are the identical three bytes,
`A0 00 BE`. The only difference in the whole program is `$0000` against
`$0001` going into `mb`, and that difference decides which code the same
address runs.

This is the idea in its entirety, and it explains why bank labels resolve the
way they do. A label inside `bank $00` is at bank offset 0, which is the
address `$BE00` — not because the assembler chose to put it there, but because
that is where bank offset 0 appears when the window shows that bank. Every
bank's first byte has the same address, because they are all the same window.

## The floor under your feet

Now the price. Consider what happens if the instruction that writes to `mb` is
itself inside the window.

The processor fetches it, executes it, and the 16 KB containing it is
replaced. `ip` still points just past the instruction, but that address now
holds a byte from a different bank — a byte that was never meant to be reached
by falling off the end of a `mov`. The processor decodes whatever is there and
carries on.

There is no fault for this. The machine has no way to know that the bytes it
is now fetching are not the ones it was reading a moment ago. [`isa.md`
§3.2](../isa.md) records the behaviour as undefined, which is the honest
description: what happens next depends on what the new bank happens to contain.

So the code that performs a switch must not live in the region being switched.
The standard answer is a **trampoline** — a short routine somewhere permanent
that takes the bank number, writes it, and jumps onward. Code in a bank that
wants to reach another bank jumps out to the trampoline, and the switch happens
on ground that does not move. Low RAM, `$0100..$0FFF`, exists partly for this:
it is flat, and no write to `mb` can affect it.

The Gero compiler generates one and routes every cross-bank call through it,
saving the caller's bank, switching, running the callee, and restoring the bank
on return. It keeps that chain of saved bank numbers in low RAM for the same
reason, so that nested cross-bank calls — including one entered from an
interrupt handler — unwind correctly.

## Why the stack is not up there

The same argument applies to data, and to one piece of data in particular.

Suppose the stack lived inside the window. A routine pushes its return address
and some saved registers; the program switches banks; the routine returns. It
pops from an address that now belongs to a different bank, gets whatever bytes
are sitting there, and jumps to them. The program does not crash at the switch.
It crashes later, somewhere unrelated, in a way that depends on the contents of
an unrelated bank.

Gero avoids this by construction rather than by discipline: `sp` boots at
`$7FFE`, the top of **user RAM**, and the bank window starts at `$BE00`, well
above it. The stack is below the window and grows further away from it. There
is no arrangement of ordinary pushes that walks a frame into switched memory.

That is why the address space is laid out with the window below the IO page
instead of at the top of memory, and why the boot value of `sp` is the number
it is — [`isa.md` §8](../isa.md) gives the three constraints that fix it, of
which this is one. It is worth noticing as a piece of design: the hazard was
not documented and left to the programmer, it was removed by choosing the
addresses so that the mistake cannot be made.

Interrupt handlers inherit the same concern from the other direction. A
handler that switches banks and returns without restoring `mb` leaves the
interrupted code reading a window it did not ask for, which is why the
previous chapter listed `mb` beside the general registers as something a
handler must put back.

## Banks are storage, not memory

One habit to unlearn. A bank is not extra RAM that a program can spread data
across freely; only one is visible at a time, and reaching a byte in another
one means a switch, with everything above to respect.

That makes banks suit some things much better than others. Code that runs as a
unit — a level, an enemy's behaviour, a screen's worth of dialogue — fits well,
because the program switches once and then stays put. Data that is walked
together fits well for the same reason. What fits badly is anything touched in
an interleaved way: a structure whose fields are split across two banks costs a
switch per access, and the cost is not only time but the discipline of making
sure nothing else depended on the window in between.

So the question when reaching for banking is not "where is there room?" but
"what is used together?". That is a question about your program rather than
about the machine, which is generally where the interesting design questions
end up.

The directive that places code in a bank, and the file-per-bank convention for
programs larger than one file, are in [`asm.md` §5](../asm.md).

## What you now know

A sixteen-bit address space cannot be enlarged, so banking changes what an
address means instead: a 16 KB window shows one bank at a time and `mb`
chooses. Every bank's first byte shares the same address, which is why the same
`call` reaches different code. Switching from inside the window pulls the
ground out from under the running instruction, so the switch happens on a
trampoline in flat memory. The stack is kept out of the window by where `sp`
boots, which turns a lurking bug into an impossibility. And a bank is a unit of
storage to be switched to and worked in, not extra room to scatter things
across.

One thing has been true of every program so far: when it halts, everything it
computed is gone. The next chapter fixes that.
