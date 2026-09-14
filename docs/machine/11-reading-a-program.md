# 11. Reading a program you did not write

Most of the assembly you will meet is not yours. It is an example whose trick
you want, a routine in a cart you are curious about, or something you wrote
long enough ago that it has become somebody else's work.

Reading is a different skill from writing, and a more useful one to practise
deliberately, because nobody teaches it directly. Writing starts from what you
meant and produces instructions. Reading starts from instructions and has to
recover what someone meant — from a program that no longer contains their
names, their comments, or their reasons.

This chapter takes one unfamiliar program and works it out. The method matters
more than the program.

## Look at the shape first

Before reading a single instruction, ask what kind of thing you are holding.

```bash
gero info fib.gx
```

```text
file:    fib.gx
size:    509 bytes
magic:   GERO
version: 0x0200
entry:   0x0000
image:   88 bytes
banks:   none
sram:    none
debug:   yes (symbols: 3)
lines:   31 rows across 1 file
```

That is a useful minute's work. The program is 88 bytes of actual image inside
a 509-byte file, so most of the file is metadata. It has no banks, so
everything is in one flat piece and chapter 7 is not involved. It has no SRAM,
so it saves nothing and chapter 8 is not involved either. It begins at
`$0000`.

And it carries debug information: three named symbols and a table of 31 source
lines. That tells you the disassembly will have real names in it, which is the
difference between an afternoon and ten minutes.

Knowing what a program *does not* do is as valuable as knowing what it does.
Three of this book's chapters just became irrelevant to the task.

## Follow the entry point

```bash
gero disasm fib.gx
```

```text
0000:  10 0A 00 02     mov   $000A, r1  ; entry point
0004:  A0 21 00        call  fib
0007:  11 02 03        mov   r1, r2
000A:  72 02 04        shr   r1, $04
000D:  A0 43 00        call  print_nibble
0010:  11 03 02        mov   r2, r1
0013:  60 0F 00 02     and   $000F, r1
0017:  A0 43 00        call  print_nibble
001A:  10 0A 00 02     mov   $000A, r1
001E:  FC 10           int   $10
0020:  FF              hlt
```

Read that as a sentence. Ten goes into `r1`; something called `fib` is called;
whatever comes back is copied to `r2`; `r1` is shifted right four bits and
passed to `print_nibble`; the saved copy is masked to its low four bits and
passed to `print_nibble` again; a newline is printed.

You can now describe the program without having read the routines it calls: it
computes `fib(10)` and prints the answer as two hexadecimal digits. The shift
and the mask are the giveaway — splitting a byte into its high and low four
bits is what printing hex looks like, and once you have seen the idiom you
will recognise it forever.

That is the first real technique. Read the top level first and treat every
call as a black box named by what it appears to do. You can always go into a
routine later, and most of the time you will not need to.

## Recognise the shapes

Now `fib` itself, which is where the interesting reading is:

```text
0021:  80 02 02 00     cmp   r1, $0002
0025:  94 42 00        jlt   &0042
0028:  31 02           push  r1
002A:  49 02           dec   r1
002C:  A0 21 00        call  fib
002F:  32 03           pop   r2
0031:  31 02           push  r1
0033:  11 03 02        mov   r2, r1
0036:  43 02 00 02     sub   $0002, r1
003A:  A0 21 00        call  fib
003D:  32 03           pop   r2
003F:  41 03 02        add   r2, r1
0042:  A2              ret
```

Three things to notice, each an instance of something this book has already
covered.

The routine begins at `$0021` and the `call` at `$002C` targets `$0021`. A
routine calling its own address is **recursion**, and spotting it is a matter
of comparing two numbers. It happens again at `$003A`.

The `jlt` at `$0025` jumps to `$0042`, which is the `ret`. So a small argument
returns immediately without recursing — that is the base case, and every
recursive routine must have one or it never terminates.

And `push r1` before each recursive call, `pop r2` after: chapter 5's
preservation discipline, applied because `fib` clobbers `r1` and the caller —
which is `fib` itself — still needs it.

Read together, the shape is the standard recursive Fibonacci: if the argument
is below two return it unchanged, otherwise compute `fib(n-1)`, save it,
compute `fib(n-2)`, and add.

None of that required cleverness. It required knowing what a base case looks
like in instructions, what a recursive call looks like, and what saving a
register across a call looks like — which is to say, it required having
written those things yourself.

## What the debug section is worth

Look closely at the two kinds of jump target in that listing. `call fib` and
`call print_nibble` have names. `jlt &0042` and `jmp &0055` have bare
addresses.

The difference is the debug section. `fib` and `print_nibble` are top-level
labels and appear in the symbol table; the targets inside a routine were local
labels, which do not. So the disassembler prints what it knows and an address
where it does not.

That contrast is the argument for keeping debug information. The version with
names reads almost like the source. Strip it and every `call` becomes a bare
address, and you are left recovering by hand which addresses are routines and
what each one is for — possible, and an order of magnitude slower. Every image
the toolchain produces carries the section; the `.gx` format permits one
without it, for a host that needs the bytes back.

The section also holds the line table — the 31 rows `gero info` reported —
which maps addresses back to lines of source. That is what a debugger uses to
show you a source line when you stop at an address, and it is what makes
source-level debugging of assembly possible at all.

## Confirm by running it

Reading gets you a hypothesis. Running turns it into a fact, and it costs
nothing:

```bash
gero run fib.gx
```

```text
37
```

`fib(10)` is 55, and 55 in hexadecimal is `37`. The hypothesis holds — both
the arithmetic and the guess that those two calls were printing hex digits.

Chapter 9's counter has something to add here too:

```bash
gero run fib.gx --cycles
```

```text
cycles: 1431
```

Fourteen hundred instructions to compute the tenth Fibonacci number, which is
a lot for a number you could reach by adding ten times. That number is itself
a reading: naive recursive Fibonacci recomputes the same values repeatedly,
and the cost grows exponentially. You can see the algorithm's character in the
measurement without having analysed it — and if you wanted to make this
program fast, the counter now gives you a baseline to beat.

## When reading is not enough

A disassembly is static. Some questions are about what happens, not what is
written: which branch actually runs, what a register holds at a particular
moment, whether a loop terminates.

For those, step the program. [`wasm.md`](../wasm.md) specifies a
browser playground with a source-level debugger built on the same debug
section this chapter has been using — breakpoints, stepping, registers and
memory as the program runs. The specification lives in this repository; the
application itself is built elsewhere on top of it.

The method does not change. You still read the shape first, treat calls as
black boxes until you need them, and recognise idioms you have written
yourself. Stepping just answers the questions that reading alone leaves open.

## What you now know

Start with `gero info`, because knowing a program has no banks and no saved
data eliminates whole chapters before you read an instruction. Read the entry
point as a sentence and treat each call as a black box named by what it
appears to do. Recognise shapes rather than decoding instruction by
instruction: a routine calling its own address is recursion, a branch to the
`ret` is a base case, `push`/`pop` around a call is preservation. Named
targets come from the debug section and bare addresses are where it fell
short. Then run it and check, because a hypothesis is cheap to confirm.

That is the end of the book. You have a machine you can describe — its cycle,
its registers, its memory — and a language you can write, measure, and read.
The specifications will make sense to you now, which was the point: they were
always the authority, and this book existed to get you to where they are
useful.

What you do with a small machine is your own business. It is a good one to
have.
