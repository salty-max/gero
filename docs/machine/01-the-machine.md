# 1. The machine

A processor does one thing, over and over, for as long as it has power. It
reads a number from memory, works out which operation that number stands for,
performs it, and then reads the next one. Everything a computer has ever done
is that loop running fast enough to look like something else.

This chapter builds the mental model that the rest of the book stands on: what
the parts are, why they are shaped the way they are, and what happens between
the moment you run a program and the moment it stops. We will not write a
program yet. We will look closely at one instruction instead, because a single
instruction understood completely is worth more than a page of them half
understood.

## Instructions are numbers

Start with the thing that surprises people most. A program in memory is not
text. It is a run of ordinary bytes, and the processor gives them meaning by
position.

Here is a four-byte sequence taken from a real gero program:

```text
10 07 00 02
```

On its own that is just four numbers. To the machine it is an instruction:
*put the value 7 into register `r1`*. The first byte, `$10`, is the **opcode**
— the number that selects an operation. The processor looks at it and learns
both what to do and how many bytes of **operand** follow. In this case `$10`
means "move a 16-bit immediate value into a register", which tells it that the
next two bytes are that value and the byte after them names the destination.

The two value bytes are `07 00`, and they mean 7, not 1792. Gero stores
multi-byte values with the least significant byte first, a convention called
**little-endian**. It is not better or worse than the other order; it is a
choice, and the important part is that the machine and the assembler agree on
it. The final byte, `02`, is the index of `r1` in the register file.

Notice what this implies. Instructions are not all the same length. `$10`
needs three bytes of operand; the instruction that stops the machine needs
none. A processor with **variable-length encoding** cannot know where the next
instruction begins until it has decoded the current one. That is a real
trade: fixed-length instructions are simpler to decode and easier to jump
around in, while variable-length ones waste fewer bytes on operations that do
not need them. On a machine where a whole program might be a few kilobytes,
those bytes are worth more than the decoding simplicity.

## The cycle

With that in mind, the loop the processor runs looks like this.

It **fetches**: reads the byte at the address held in the instruction pointer.
It **decodes**: works out which operation that opcode names and how many
operand bytes to read. It **executes**: performs the operation, which may
change a register, change memory, or change the instruction pointer itself.
Then it advances the instruction pointer past what it just consumed and starts
again.

This is the **fetch-decode-execute cycle**, and it is the single most useful
idea in this book. A program does not "run" in any richer sense than this. A
loop is not a construct the machine knows about; it is what happens when an
instruction writes a smaller number back into the instruction pointer. A
function call is not a feature; it is a jump that first wrote down where to
come back to. Once you see every high-level idea as an arrangement of this one
cycle, assembly stops feeling arbitrary.

The instruction pointer is what makes the cycle self-propelling. It is a
register like the others, except that the processor reads it every cycle to
know where to look. Writing to it is how a program changes its own course, and
most of [chapter 4](04-loops-and-branches.md) is about doing exactly that
deliberately.

## Why registers exist

The processor needs somewhere to hold the values it is working on. It could
use memory for that, and some early machines nearly did. The reason it does
not is distance.

Memory is a large array of bytes that lives outside the processor. Reaching it
takes time — more time than performing the arithmetic once the value has
arrived. A **register** is storage built into the processor itself, close
enough to the part doing the work that reading one is essentially free. So a
processor keeps a small set of registers as a working surface: values come in
from memory, are operated on in registers, and go back out.

That explains why registers are fast. It also explains why there are so few of
them. Registers are expensive in the physical sense — each one costs area and
wiring inside the processor — and they are expensive in the encoding sense
too. Every instruction that names a register has to spend bits saying which
one. Gero uses a whole byte per register operand, which is generous, but a
machine with 4,096 registers would need twelve bits for every single operand
and would spend most of its program size naming things.

More importantly, a small register file is a design that admits what it is
for. Registers are scratch space for the operation in front of you, not a
place to keep your program's data. The moment you have more live values than
registers, some of them must live in memory and be brought in when needed.
Recognising that is not a limitation to work around; it is the actual shape of
the problem, and every compiler for every machine spends much of its effort on
exactly this question.

## The register file

Gero has fifteen registers, each holding sixteen bits. Eight of them —
`r1` through `r8` — are general purpose, which means the machine attaches no
meaning to them and you may use them for anything.

The rest have jobs. `acu`, the **accumulator**, is the implicit destination
for the short forms of arithmetic instructions and the place where the high
half of a multiplication lands; it is a survivor of an era when a processor
had one working register and everything happened there. `ip` is the
instruction pointer from the previous section. `sp` and `fp` manage the stack,
which chapter 5 covers. `mb` selects which bank of memory
is currently visible, the subject of chapter 7. `im` and
`flg` control interrupts and hold the results of comparisons, which are
chapter 6 and [chapter 4](04-loops-and-branches.md)
respectively.

The full table, with the index the machine uses for each register and the
exact fault a program gets for naming one that does not exist, is [`isa.md`
§2](../isa.md). You do not need to memorise it. You need to know that the set
is small, that most of it is yours, and that a few entries have standing jobs
which the machine itself depends on.

## Memory as one long array

Everything that is not a register lives in memory, and memory is simpler than
it first appears: a single array of bytes, numbered from 0. Gero addresses are
sixteen bits wide, so the numbering runs from `$0000` to `$FFFF` and the array
is 65,536 bytes long. That is the whole of it. There is no separate place for
code and data, no distinction the hardware enforces between a number you meant
as an instruction and a number you meant as a value.

This is worth sitting with, because it has a consequence people often find
unsettling: a program can read its own instructions as data, and can write
data into the region it is about to execute. Nothing stops it. The machine
does not know the difference, because at the level of the array there is no
difference. The discipline that keeps code and data apart is a convention held
up by the assembler, the compiler, and the programmer — not by the processor.

Since the hardware does not impose a structure, one is agreed on instead. The
address space is divided into regions, each sized for what tends to live
there: a zero page at the very bottom, then low RAM, then the table the
processor reads when an interrupt arrives, then the large middle where your
code, data, heap and stack all live, and above that two regions a host can
claim for devices and a window through which banked memory appears.

Two of those are enforced by the machine — the vector table, because the
processor itself reads addresses out of it, and the bank window, because what
appears there depends on `mb`. The rest is convention, and a host is free to
map a device anywhere. The exact ranges are a table in [`isa.md`
§3](../isa.md), and that is deliberately the only place this book will put
them: a memory map printed in two documents is a memory map that will
eventually say two different things, and the one you are reading is not the
one the machine consults.

The region worth noticing now is the first one. The **zero page** is ordinary
memory with one property: every address in it fits in a single byte. An
instruction that reaches into the zero page can therefore be encoded more
compactly than one carrying a full sixteen-bit address, and that saving
applies to every use. This is why the region exists, why it is only 256 bytes,
and why a program that cares about size puts its most frequently touched
values there. [Chapter 3](03-memory.md) uses it properly.

## One instruction, end to end

We now have enough to follow the four bytes from the start of the chapter all
the way through.

Suppose `ip` holds `$1200`, the first address of user RAM, and memory from
there reads `10 07 00 02`.

The processor fetches the byte at `$1200` and gets `$10`. It decodes that as
"move a 16-bit immediate into a register" and, from the opcode alone, knows
three operand bytes follow. It reads `$1201` and `$1202` — `07` then `00` —
and assembles them, least significant byte first, into the value 7. It reads
`$1203` and gets `02`, the index of `r1`. It executes: `r1` becomes 7. Then it
advances `ip` by four, to `$1204`, and fetches again.

Nothing was printed, nothing was stored to memory, and from the outside
nothing happened at all. This is normal and it is worth saying plainly,
because it is the first thing that trips people coming from a high-level
language. A processor does not report on itself. Making a result visible is a
separate act, performed by separate instructions, and one of the first things
the next chapter does is arrange for one.

## What you now know

A program is bytes, and an opcode gives those bytes meaning. The processor
runs one cycle — fetch, decode, execute — and every control structure you have
ever used is that cycle with the instruction pointer redirected. Registers are
a small, fast working surface, small because they are costly and because
scratch space is all they are meant to be. Memory is one flat numbered array
with regions agreed on by convention rather than enforced by hardware.

That is the machine. The next chapter puts a program on it.
