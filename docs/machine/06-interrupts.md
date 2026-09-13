# 6. Interrupts

Every transfer of control so far has been the program's own decision. A jump,
a call, a return — each happens because an instruction said so, at a moment
the program chose.

An interrupt is the other kind. Something outside the program demands
attention, and the processor stops what it was doing mid-stream and goes to
deal with it. You have been using one since chapter 2 without looking at it:
`int $10`, the request that prints a character. This chapter opens it up.

The chapter also invalidates something the last one relied on. When you write
a `call`, you can see the call site and reason about what is live across it.
An interrupt has no call site. It can arrive between any two instructions, and
the code it lands on top of has no idea it happened.

## The vector table

When an interrupt fires the processor needs an address to jump to, and it
cannot be told one — nobody is there to pass an argument. So the address is
left somewhere agreed in advance, and the processor goes and reads it.

That place is the **interrupt vector table**, a region of memory holding one
address per interrupt number. Gero puts it at `$1000` and gives it 256 entries
of two bytes each, so the handler for interrupt `N` is the word at
`$1000 + 2N`. Interrupt `$30` reads its address from `$1060`.

There is nothing clever in the table. It is ordinary memory that the processor
happens to read at a particular moment, which means a program can install a
handler simply by writing an address into it. The mechanism is the same at the
start of the program or halfway through, and a program can change its mind
about a handler while running.

The simplest way to fill in an entry is to place it when the image is built,
with `org`:

```asm
const PRINT = $10

main:
  mov 'a', r1
  int $30
  int PRINT
  mov $0A, r1
  int PRINT
  hlt

tick:
  mov '!', r1
  int PRINT
  rti

org $1060
data16 VECTOR_30 = @tick
```

`org` sets the address the assembler emits at, so the `data16` after it lands
at `$1060` — inside the vector table — and holds `tick`'s address. By the time
the program runs, the entry is already there. The cost is an image that spans
as far as `$1060`, since a file must cover every address it writes into. A
program that would rather stay small can write the entry at run time instead,
which [`asm-cookbook.md`](../asm-cookbook.md) shows.

`int $30` then raises interrupt `$30`, and `rti` — return from interrupt —
resumes whatever was interrupted.

## What entry and exit actually do

The sequence is deliberately close to `call`, with one important difference.

On entry the processor pushes `ip`, `fp` and `flg`, sets the interrupt-disable
flag so a second interrupt cannot arrive inside the first, and jumps to the
address in the table. `rti` pops all three back and carries on.

The flags register is in that list and was not in `call`'s, which matters more
than it looks. An interrupt can arrive between a `cmp` and the `jge` that
reads it — that is exactly the kind of gap it can land in — and if the handler
performed any arithmetic, the comparison's result would be gone by the time
the branch ran. Saving `flg` closes that hole.

Restoring `flg` also restores the interrupt-disable bit to whatever it was, so
the handler does not have to remember to re-enable interrupts on the way out.
A handler that wants to allow nesting can clear the bit itself and get nested
behaviour without any other change. The two layers of masking — the global
flag and the per-vector mask in `im` — are described in [`isa.md`
§6.4](../isa.md).

## What the handler must not damage

Here is the part that costs people real debugging time.

`ip`, `fp` and `flg` are saved. Nothing else is. The general-purpose registers
and the bank selector `mb` are exactly as the handler leaves them when the
interrupted code resumes:

```text
!!
```

That is the output of the program above, and it should have been `!a`. `main`
put `'a'` in `r1` and raised the interrupt. `tick` used `r1` to hold its own
`'!'`, and when `main` resumed and printed `r1`, the character it had loaded
was gone.

This is the same clobbering that chapter 5 showed across a `call`, and it is a
different problem despite looking identical. With a call you can see the call
site. The registers live across it are visible in the surrounding code, and a
convention can assign responsibility because both sides know a call is
happening. An interrupt has no call site to look at. Every instruction
boundary in the entire program is a place it might arrive, so there is no
"caller" to take responsibility and no code that could have prepared.

Which settles the question: the handler saves everything it touches, because
the interrupted code cannot possibly have done it.

```asm
const PRINT = $10

main:
  mov 'a', r1
  int $30
  int PRINT
  mov $0A, r1
  int PRINT
  hlt

tick:
  push r1
  mov '!', r1
  int PRINT
  pop r1
  rti

org $1060
data16 VECTOR_30 = @tick
```

```text
!a
```

Two instructions, and the handler becomes invisible to the code it
interrupted. That is the standard the discipline aims at, and it is worth
stating as a goal rather than a rule: a handler should leave the machine
exactly as it found it, in every respect the interrupted program could notice.

`mb` belongs to that list as much as the registers do. In a banked program a
handler that selects a bank and returns leaves a different 16 KB visible
through the window, and the interrupted code carries on reading memory that
has silently been replaced underneath it. The next chapter is about what that
means.

The Gero compiler handles all of this for `@interrupt` handlers
automatically — the general registers always, and `mb` whenever the program
declares banked code. That is a fair illustration of what a compiler is for:
not that the discipline is hard, but that it must be applied without fail
every time, and a person doing it by hand will eventually forget one register
in one handler.

## Software and hardware are the same door

`int $30` is a program deliberately raising an interrupt on itself, which
seems like an odd thing to want. It becomes less odd when you notice that the
two things sharing this mechanism are the same shape from the processor's
side.

A hardware device asserting a line wants to run some code, right now,
wherever the program happens to be. A program asking the host to print a
character wants to run some code that lives outside itself. Both need a
transfer of control to an address the program did not name, and both need the
interrupted state preserved. One table serves both.

That is why `int $10` has been printing your characters since chapter 2. It is
not a special instruction with printing built in — it is this same mechanism,
with the host having put something at that entry that knows how to reach a
terminal. Vectors `$10` through `$1F` are reserved for host services by
convention, `$20` and up are yours, and the low range belongs to faults the
processor raises itself. The division is in [`isa.md` §6.1](../isa.md).

## What you now know

An interrupt transfers control at a moment the program did not choose, to an
address it reads from a table in memory. Entry saves `ip`, `fp` and `flg` —
the flags because an interrupt can land between a comparison and its branch —
and restoring `flg` makes nesting control automatic. Everything else is the
handler's responsibility, and unlike a called routine it has no caller to
share the work with, so it saves whatever it touches. Software interrupts and
device interrupts use one mechanism because from the processor's side they are
the same request.

The warning about `mb` is the bridge to the next chapter: what it means for
memory to change underneath running code, and how a program more than 64 KB
long fits into an address space that is not.
