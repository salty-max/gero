# The Gero Machine

This book teaches the Gero virtual machine and the assembly language that
speaks to it directly. It also teaches the ideas that machines like this one
are built from. A register, an addressing mode, a flag, and an interrupt are
introduced as answers to problems before they are introduced as syntax to
remember.

The gero machine is a good one to learn on because it is small. It has fifteen
registers, a sixteen-bit address space, and an instruction set you can read
through in an afternoon. Nothing in it is hidden behind a decade of backwards
compatibility. When you write an instruction here, you can see the bytes it
became and follow what the processor does with them, which is exactly the loop
that makes the subject click.

You need to be comfortable creating a text file and running a command in a
terminal. You do not need to have written assembly, and you do not need to
have used the other language. When this book uses an idea from programming
generally, it explains it.

## The other book

**[The Gero Book](../book/README.md)** teaches Gero, the high-level language
for the same machine: types, functions, classes, modules, and a cart built
across its chapters.

It is a companion to this book, not a prerequisite for it. The two languages
are peers. They compile to the same bytecode and run on the same VM, and
neither is the advanced form of the other — [Gero and
assembly](../book/addendum-b-assembly.md) compares them on one worked example
with the cycle counts measured. If your goal is to understand how a small CPU
works, begin here. Nothing in the other book is assumed.

Read that book to learn programming by making a cart. Read this one to learn
what the machine is doing while that cart runs.

## Contents

1. [The machine](01-the-machine.md) — what a processor is made of, why
   registers are few, and the cycle that runs every program.
2. [First instructions](02-first-instructions.md) — write, assemble, run, and
   then read your own program back as bytes.
3. [Memory](03-memory.md) — addressing modes, the zero page, labels, and
   putting data in the image.
4. [Loops and branches](04-loops-and-branches.md) — flags, comparison, and how
   a decision is actually made.
5. [The stack and subroutines](05-the-stack.md) — why nesting forces a stack,
   and where a calling convention comes from.
6. [Interrupts](06-interrupts.md) — control you did not ask for, and what a
   handler owes the code it lands on.
7. [Banking](07-banking.md) — reaching more storage than an address can name,
   without the floor moving under you.
8. [Persistence](08-persistence.md) — the part of the machine that remembers.
9. [Counting cycles](09-counting-cycles.md) — measuring a program, making it
   cheaper, and knowing what the measurement leaves out.
10. [Talking to a host](10-talking-to-a-host.md) — the two doors out of a
    sealed instruction set, and what a console adds.
11. [Reading a program you did not write](11-reading-a-program.md) — working
    out an unfamiliar disassembly, and what the debug section is worth.

## How this book relates to the specifications

The specifications define the machine. This book teaches it. When a chapter
needs an exact rule — the full opcode table, the encoding of an operand, the
precise fault a bad register index raises — it links to
[`isa.md`](../isa.md) or [`asm.md`](../asm.md) rather than restating the rule
in different words. Two documents stating the same rule eventually state it
differently, and then a reader has no way to tell which one is lying.

So the specs are the authority and this book is the path into them. By the end
you should be able to read them directly, which is the real goal.

Every code block in this book is assembled by CI. An example that quietly
stopped working is worse than no example at all, because a person learning the
subject cannot tell whether the mistake is theirs or the book's.
