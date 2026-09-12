# The Gero Book

This book teaches **Gero**, the high-level language for the Gero virtual
machine. It also teaches the programming ideas behind the language. A
variable, a branch, a function, and a type are introduced as ways to solve
problems before they are introduced as syntax to remember.

You only need to be comfortable creating a text file and running a command in
a terminal. You do not need to have written a program, used assembly, targeted
a console, or heard of a bytecode VM. When the book uses one of those ideas,
it explains it.

Across the chapters we build one small role-playing fight. It begins as two
numbers, gains decisions and repetition, then grows into fighters, items,
modules, tests, and finally a cart you can run and change.

## The other book

**The Gero Machine** teaches the VM itself and its assembly language:
registers, addressing, interrupts, banking, and counting cycles.

It is a companion to this book, not its sequel. The two languages are peers
that produce the same bytecode. [Gero and assembly](addendum-b-assembly.md)
compares them with a measured example. If your goal is to learn how a small
CPU works, you can begin with The Gero Machine. Nothing in this book is a
prerequisite.

Read this book to learn programming by making a cart. Read the other one to
learn what the machine does while that cart runs.

## Contents

1. [What Gero is](01-what-gero-is.md) — write and run a first program, then
   learn what the compiler produced.
2. [Values and types](02-values-and-types.md) — names, changing state, integer
   sizes, text, and why there are no floats.
3. [Control flow](03-control-flow.md) — decisions, repetition, ranges, and the
   state of a loop.
4. [Functions](04-functions.md) — naming operations, passing information, and
   returning answers.
5. [Collections](05-collections.md) — tuples, arrays, `Vec`, copying, and
   moving growable storage.
6. [Enums and match](06-enums-and-match.md) — representing alternatives and
   making the compiler check every case.
7. [Classes](07-classes.md) — keeping data with the operations that protect
   its rules.
8. [Modules](08-modules.md) — splitting a growing program into files and
   building it as a project.
9. [Numbers that are not integers](09-fixed.md) — fixed-point arithmetic and
   the cost of fractions on an integer machine.
10. [Testing and measuring](10-testing.md) — checking behavior and measuring
    work in VM cycles.
11. [Reaching the machine](11-reaching-the-machine.md) — the narrow bridge to
    assembly, banks, and interrupts.
12. [A cart, end to end](12-a-cart.md) — assemble the complete fight, test it,
    build it, and inspect what ships.

Addenda: [Installing Gero](addendum-a-installing.md),
[Gero and assembly](addendum-b-assembly.md).

## How to read it

Type the code and change it. Reading a program tells you what it says; running
and modifying it teaches you what it means. Each chapter gives you a small
working program before adding it to the fight.

Every `gero` block is parsed by CI, and the complete fight is compiled, run,
and compared with its expected output. A few examples are deliberately wrong
because learning to read an error is part of learning the language. The
sentence before such a block says that it does not compile, and the book shows
the relevant diagnostic immediately after it.

In the lab, **Run** compiles a block and prints its output underneath. On your
own machine, use `gero compile` and `gero run`; the first chapter walks through
both commands.
