# 2. First instructions

The previous chapter described a machine. This one puts a program on it, and
then does something that high-level languages rarely let you do: reads the
program back in the form the machine actually received, and checks that it is
what you meant.

That round trip — write, assemble, run, disassemble — is the loop this book
uses throughout. It is worth building the habit now, on a program small enough
that nothing can hide in it.

## A program that shows something

Create a file named `letter.gas`:

```asm
const PRINT = $10

main:
  mov 'A', r1
  int PRINT
  hlt
```

Four lines do the work. Take them in order.

`const PRINT = $10` gives the name `PRINT` to the number `$10`. It is not an
instruction and it produces no bytes; it is an instruction to the assembler,
telling it to substitute the value wherever the name appears. Assembly
programs accumulate magic numbers quickly, and naming them is the cheapest way
to keep a program readable.

`main:` is a **label**. A label gives a name to a position in the program, and
the assembler records the address that position ends up at. `main` is special
only by convention: it is where execution starts. Labels are the mechanism
that lets you refer to a place without knowing its address, which matters
because you almost never do — inserting one instruction would shift everything
after it.

`mov 'A', r1` puts the value of the character `A` into register `r1`. Gero
reads operands as **source first, destination second**, so this moves `'A'`
*into* `r1`. That order is uniform across the instruction set, and it is worth
fixing in your head now because the opposite convention is equally common in
the world and mixing them up produces programs that run and do the wrong
thing. The exact rule, including the two families that deliberately differ, is
[`asm.md` §2.4](../asm.md).

`int PRINT` asks the host for something the processor cannot do by itself.
Printing is not arithmetic; there is no wire inside a CPU that reaches a
terminal. What `int` does is raise a **software interrupt**, which suspends
the program and hands control to whoever is listening on that vector. By
convention vector `$10` means "print the character in `r1`", and the `gero`
command-line tool provides it. [Chapter 6](06-interrupts.md) explains the
mechanism properly; for now it is enough that this is how a program reaches
the outside world, and that reaching the outside world is always somebody
else's job.

`hlt` stops the machine. Without it the processor would carry on fetching
whatever bytes happened to follow, decode them as instructions, and execute
them — the cycle from chapter 1 does not stop on its own, and there is no end
of the program for it to notice.

## Assemble it and run it

```bash
gero asm letter.gas
```

The assembler reads the text and writes `letter.gx`, reporting what it made:

```text
letter.gx (193 bytes, 0 banks, debug: yes)
```

Then run it:

```bash
gero run letter.gx
```

```text
A
```

The program is six bytes of instructions. The other 187 are the container
around them — a header, and the debug information that lets tools map bytes
back to the lines you wrote. Every image the toolchain produces carries it,
and [chapter 11](11-reading-a-program.md) puts it to work.

## Reading your program back

Here is the part that repays the effort. Ask the toolchain to turn the file
back into instructions:

```bash
gero disasm letter.gx
```

```text
0000:  10 41 00 02     mov   $0041, r1  ; entry point
0004:  FC 10           int   $10
0006:  FF              hlt
```

Each line is one instruction: the address it sits at, the exact bytes, and how
those bytes read as an operation.

The first line is the one from chapter 1, and now you have produced it
yourself. `mov 'A', r1` became `10 41 00 02`, and the disassembler shows it as
`mov $0041, r1` — not `mov 'A', r1`. The character notation was never in the
program. `'A'` is a way of writing 65 that says something about your intent to
the next person reading the source, and the assembler resolved it to a number
before any bytes existed. The machine has no concept of text at all; it has
numbers, and a convention about which numbers stand for which marks when
something eventually draws them.

The addresses confirm the variable-length encoding from chapter 1. `mov`
started at `0000` and `int` starts at `0004`, so `mov` occupied four bytes.
`int` occupies two, and `hlt` one. The processor learns each of those lengths
from the opcode, which is why it can find the next instruction at all.

Get into the habit of running `disasm` on your own programs. It is the only
way to see what you actually wrote rather than what you believe you wrote, and
it costs a second.

## Arithmetic, and making a result visible

Registers are for working on values, so let us work on some. Create
`sum.gas`:

```asm
const PRINT = $10

main:
  mov $0003, r1
  mov $0004, r2
  add r2, r1
  add '0', r1
  int PRINT
  hlt
```

`$` marks a hexadecimal number, so `$0003` is 3. The first two instructions
load the values. `add r2, r1` adds — source first again, so `r2` is added
*into* `r1`, which now holds 7. Registers are both where operands come from
and where results go; there is no separate result register and no expression
being built up anywhere. Each instruction modifies the working surface in
place.

Then `add '0', r1`, which deserves an explanation because it looks like a
trick and is really a consequence. `r1` holds the number 7. To print it we
must give the host the number that stands for the *character* seven, and in
the encoding everyone uses, the digits are laid out consecutively starting at
48. So the character for a digit is the digit plus 48 — which is what `'0'`
is. Adding it converts a value into the symbol for that value.

This is the first appearance of a theme the whole book returns to. The machine
gives you numbers and a handful of operations. Anything that looks like a
richer idea — text, a decimal number on screen, a data structure — is a
convention built on top, and down here you build it yourself.

```bash
gero asm sum.gas
gero run sum.gx
```

```text
7
```

## What the assembler chose

Disassemble this one too, because it has something to show:

```text
0000:  10 03 00 02     mov   $0003, r1  ; entry point
0004:  10 04 00 03     mov   $0004, r2
0008:  41 03 02        add   r2, r1
000B:  40 30 00 02     add   $0030, r1
000F:  FC 10           int   $10
0011:  FF              hlt
```

Look at the two `add` instructions. They have the same mnemonic and different
opcodes: `$41` for `add r2, r1` and `$40` for `add $0030, r1`. And they have
different lengths — three bytes against four.

That is not an inconsistency, it is the encoding being economical. Adding one
register to another needs two operands, and a register index is one byte
each: three bytes in total. Adding an immediate value needs that value, which
is sixteen bits: four bytes. Rather than pad the register form to match, the
instruction set gives the two forms separate opcodes and lets each be as long
as it needs.

So `add` in the source is not one instruction. It is a small family, and the
assembler picks a member based on the operands you wrote. This is the
assembler's main job, and it is why writing assembly is not the same as
choosing bytes by hand. You express intent at the level of "add these two
things"; it selects the encoding. The full list of forms for each mnemonic is
in [`isa.md` §5](../isa.md).

The consequence worth carrying forward is that instruction choice affects
program size, and you can measure it. `add r2, r1` costs a byte less than
`add $0004, r1`, so a value you use repeatedly may be worth putting in a
register once rather than naming as an immediate each time. On a machine whose
whole address space is 64 KB, that reasoning is routine. We will do it
deliberately in [chapter 9](09-counting-cycles.md), with the cycles measured
rather than guessed.

## What you now know

You can write, assemble, run, and disassemble a program, which is the complete
working loop for everything that follows. You have seen that operands read
source-first, that reaching the outside world means asking a host, and that a
program must stop itself. You have watched a character literal resolve to a
number before the machine ever saw it, and watched one mnemonic resolve to two
different opcodes depending on what you asked it to add.

Both of these programs kept everything in registers. That works while you have
two values and stops working almost immediately after. The next chapter is
about memory: how to reach it, how to name places in it, and how to put data
in your program in the first place.
