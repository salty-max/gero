# 5. The stack and subroutines

You can now write any computation the machine is capable of. What you cannot
do is give a piece of code a name and use it from two places, because a jump
knows where it is going and not where it came from.

This chapter solves that, and the solution turns out to be a data structure —
one whose shape is forced by the problem rather than chosen for elegance. That
is worth watching happen, because the same argument produces the same
structure on every machine you will ever use.

## The problem is getting back

Suppose you want a routine that prints the character in `r1`, and you want to
use it three times. Jumping to it is easy. Returning is not: the routine has
one `jmp` at the end and it must land in three different places depending on
who asked.

Storing the return address in a fixed location almost works. The caller writes
down where to come back to, the routine reads that slot and jumps there. It
handles two callers, ten callers, any number — until a routine calls another
routine. Then the inner call overwrites the slot, and the outer one has
forgotten where it came from.

So the storage cannot be a single slot. It must hold several return addresses
at once, and the order they come back in is fixed by the structure of the
problem: the most recently made call is always the first to return. Calls nest
the way brackets nest; they cannot overlap.

A structure where the last thing in is the first thing out is a **stack**, and
this is where the name in your programming language comes from. It is not that
someone chose a stack and built calling on top. It is that nesting has exactly
one shape and the stack is that shape written down.

## Push and pop

The machine gives you the two operations and a register to track them. `sp`
holds the address of the top of the stack. `push` moves `sp` down by two and
writes there; `pop` reads and moves `sp` back up.

Downward is the convention here and on most machines, for a reason worth
knowing. Your program and its data grow upward from low addresses. If the
stack also grew upward, the two would collide early and the space each could
use would have to be decided in advance. Starting the stack high and growing
it down lets each take what it needs and only meet if the program genuinely
runs out of memory.

`sp` begins at `$7FFE`, the top of user RAM — not the top of memory, which
belongs to the host and to banked storage. Nothing checks for collision: the
gero stack, like the 6502's, wraps silently if you push far enough. That is a
real hazard and an honest one. The exact boot value and the three constraints
that fix it there are in [`isa.md` §8](../isa.md).

## Call and return

With a stack, the routine problem solves itself. `call` pushes the address of
the instruction after itself, then jumps. `ret` pops that address into `ip`.
Nesting works because the stack holds every level at once.

```asm
const PRINT = $10

main:
  mov 'a', r1
  call emit
  mov 'b', r1
  call emit
  mov $0A, r1
  call emit
  hlt

emit:
  int PRINT
  ret
```

```text
ab
```

Three calls, one routine, three correct returns. The disassembly shows there
is no magic in it:

```text
0000:  10 61 00 02     mov   $0061, r1  ; entry point
0004:  A0 16 00        call  emit
0007:  10 62 00 02     mov   $0062, r1
000B:  A0 16 00        call  emit
000E:  10 0A 00 02     mov   $000A, r1
0012:  A0 16 00        call  emit
0015:  FF              hlt
0016:  FC 10           int   $10
0018:  A2              ret
```

All three `call` instructions are the same three bytes, `A0 16 00`. What
differs is where each one sits, and therefore the return address each pushes —
`$0007`, `$000B`, `$0015`. The routine at `$0016` cannot tell its callers
apart and does not need to.

Notice that `ret` is a single byte with no operand. It takes its destination
from the stack, which is the whole point: the address is data, produced at run
time, rather than something encoded in the instruction.

## Why there is a second pointer

`call` does slightly more than push a return address. It also pushes `fp`, and
then sets `fp` to the new top of the stack. Understanding why that is worth an
extra register is understanding the calling convention.

The trouble with `sp` is that it moves. A routine that pushes a value has
changed `sp`, so anything it locates by counting from `sp` is at a different
offset before and after. Any code that saves a value and then reads it back
has to track how deep the stack currently is, and every `push` between the two
changes the answer.

So the machine keeps a second pointer that does not move: `fp`, the **frame
pointer**. It is set once on entry and stays put for the whole routine, which
makes every offset from it constant. A routine's own storage — the **frame** —
is located relative to `fp`, and the code addressing it does not care what
`sp` has done since.

That explains why `call` pushes the old `fp` before setting the new one. Each
routine needs its own frame pointer, and the one belonging to its caller has
to survive until the caller resumes. The stack already holds a chain of return
addresses; now it holds a chain of frame pointers too, and `ret` unwinds both.

Reading the two instructions together, the shape follows:

- `call` — push `fp`, push the return address, set `fp` to `sp`, jump.
- `ret` — set `sp` to `fp`, pop the return address into `ip`, pop `fp`.

Look at what `ret` does first. Setting `sp` back to `fp` discards, in one
instruction, everything the routine pushed after entry. A routine can use the
stack as scratch space freely and never balance its pushes, because returning
throws the whole frame away. That is not a convenience bolted on; it falls out
of having a pointer to where the frame began.

The precise operand order and encoding of both instructions are in [`isa.md`
§5](../isa.md).

## What the machine does not do for you

Return addresses and frame pointers are handled. Your registers are not.

```asm
const PRINT = $10

main:
  mov 'X', r2
  call noisy
  mov r2, r1
  int PRINT
  mov $0A, r1
  int PRINT
  hlt

noisy:
  mov 'z', r2
  mov r2, r1
  int PRINT
  ret
```

```text
zz
```

`main` put `'X'` in `r2` and expected to print it after the call. It printed
`z`, because `noisy` used `r2` as scratch and nothing objected. There are
eight general-purpose registers and no notion of ownership; a called routine
writes to the same eight its caller was using.

The fix is to save what you clobber and put it back:

```asm
const PRINT = $10

main:
  mov 'X', r2
  call polite
  mov r2, r1
  int PRINT
  mov $0A, r1
  int PRINT
  hlt

polite:
  push r2
  mov 'z', r2
  mov r2, r1
  int PRINT
  pop r2
  ret
```

```text
zX
```

`push` and `pop` bracket the damage, and `main` gets its value back.

Now the question that makes this a convention rather than a trick: whose job
is it? Either the caller saves what it still needs before calling, or the
callee saves what it intends to use. Both work. Both are wasteful in the same
way — the caller does not know what the callee will touch, and the callee does
not know what the caller still cares about, so either way somebody saves
registers that did not need saving.

Real machines answer this by splitting the register file in half by agreement:
some registers are the caller's problem, the rest are the callee's, and code on
both sides of a call knows which is which without being told. That agreement is
a **calling convention**. The processor does not enforce it and cannot; it is a
contract between pieces of code, and the only thing making it true is that
everyone follows it.

Gero's assembler does not impose one, which means in hand-written assembly the
contract is whatever you decide and document. The Gero compiler does impose
one, which is what lets a function written in the high-level language call
another safely without either knowing anything about the other's body.

## What you now know

A subroutine needs to remember where to return to, nesting forces that
storage to be last-in-first-out, and a stack is what that shape is called. The
machine provides `sp` and the two operations, and `call` and `ret` are those
operations composed with a jump. A second pointer exists because `sp` moves
and offsets into a frame must not, and it is that pointer which lets `ret`
discard a whole frame in one step. Register preservation is a contract between
programs, not a service from the processor.

Everything so far has been code deciding when to run. The next chapter is
about code that runs when something else decides — which breaks an assumption
this chapter quietly relied on.
