# 10. Talking to a host

Everything the machine does, it does to itself. Registers, memory, arithmetic,
branches — a complete little world, and a sealed one. Nothing in the
instruction set can draw a pixel, read a button, or write a file, because none
of those are operations on a sixteen-bit word.

Yet programs do all three. This chapter is about the boundary they cross to do
it, and about why a machine is designed with a boundary there at all rather
than with a `draw` instruction.

## What a program actually needs

Start from the requirements rather than the mechanism, because the mechanism
makes more sense that way.

A program needs to produce output a person can perceive, which the processor
cannot do. It needs input, which arrives when a person decides rather than
when the program asks. It needs state that outlives the run, which chapter 8
covered. And on a console it needs the machinery of a game — sprites, sound,
a frame that begins and ends.

None of those is arithmetic, and none can be built from arithmetic. They all
have the same shape: the program wants something done that only the world
outside it can do.

Which raises the design question. You could put those operations in the
instruction set — a `draw` opcode, a `readkey` opcode. Machines have been
built that way, and the cost is that the instruction set stops being about
computation and starts being about one particular arrangement of hardware.
Change the display and the opcodes are wrong. Run the program somewhere
without a display and they are meaningless.

So gero draws a line instead. The instruction set covers computation, which is
the same everywhere, and everything else goes through a boundary the host
implements. What sits on the far side of that boundary is not the machine's
business: a terminal, a fantasy console, a browser tab. The program does not
know and does not need to.

## Two doors

There are two ways across, which is one more than you might expect. They exist
for different reasons and the difference is worth understanding.

The first you have used since chapter 2. `int $10` raises a software interrupt
that the host has claimed, and it works because chapter 6's mechanism does not
care whether the thing that answers is inside the machine or outside it. The
host installs handlers on a few agreed vectors — `$10` prints a character,
`$21` flushes saved data — and a program reaches them the way it reaches any
other interrupt.

The second is `sys`, an instruction whose operand selects from a table of
services the VM itself provides:

```asm
main:
  mov $0000, acu
  sub $0022, acu
  sys $02
  sys $04

  mov &[@GREETING_ADDR], acu
  sys $01
  sys $04
  hlt

data8 GREETING = "machine", $00
data16 GREETING_ADDR = @GREETING
```

```text
-34
machine
```

`sys $02` prints the signed value in `acu` as decimal, `sys $01` prints a
null-terminated string whose address is in `acu`, and `sys $04` prints a
newline. Registers carry the arguments; the table is in [`isa.md`
§5.13.1](../isa.md).

Compare that to what you would write with `int $10` alone. Printing `-34`
means handling the sign, splitting the number into digits, converting each to
a character, and emitting them in the right order — thirty-odd instructions
you would have to write, debug and carry around. `sys $02` is one.

## Why both exist

The two doors answer different questions, and the split tells you something
about where a machine's edges are.

`int` is the general mechanism: a vector table, a handler, and a convention
about which numbers mean what. A host can claim any vector and provide
anything at all, and gero has no say in what. It is deliberately open-ended —
that is what makes it possible for gtx-16 to define services this machine's
designers never imagined.

`sys` is the narrow one. Its handlers are inside the VM, its table is fixed,
and an unknown number raises a fault rather than doing nothing. It exists
because some services are needed by every program on every host — printing a
number, formatting a string, allocating memory — and having each host
reimplement them would mean the same program printing differently in a
terminal and in a browser.

So `sys` is the **embedding boundary**: the surface anything hosting gero must
provide, kept small on purpose. The `isa.md` entry says so directly — "it's
the embedding boundary, not a general syscall surface. Add new syscall numbers
conservatively." Every addition is a thing every future host must implement
forever.

There is a measurable difference too, and it follows from where each is
handled. A `sys` is an instruction the VM executes, so chapter 9's counter
counts it. An `int` the host intercepts never reaches the VM's step, so it
counts as nothing. Run the program above with `--cycles` and you get 8 — one
per instruction, the two `sys` calls included.

## What the compiler uses

Look at the `sys` table and you can read the high-level language off it.
`print_int`, `print_str`, `print_fixed` are what `print` becomes.
`format_int_to_buf` and its siblings are what string formatting becomes.
`alloc` is the bump allocator behind a growable vector. `trap` is what a
failed assertion ends with.

That is not a coincidence, it is the design. The compiler does not have a
runtime library written in Gero; it has a small set of services in the VM and
emits calls to them. When you write `print x` in the other book's language,
the bytes that come out are a `sys`.

Which means the two languages are on the same footing here as everywhere else.
The compiler is not using a privileged channel — it is using the door you have
just been using by hand, with the same arguments in the same registers.

## What a console adds

`gero run` provides the minimum: characters out, saves flushed. A fantasy
console needs considerably more, and gtx-16 is the worked example.

Its additions are not syscalls. They are memory — the IO page at the top of
the address space, where the host maps device registers, so that writing to an
address changes what is on screen. A program sets a display mode by storing to
a location, and reads which buttons are held by loading from another.

That is **memory-mapped IO**, and it is the dominant way real machines do
this. It costs no new instructions: `mov` already writes to addresses, so a
device that answers at an address is reachable with the instruction set you
already have. Chapter 3's `mov r1, &2620` becomes a way to talk to hardware
the moment something is listening at `$2620`.

It also explains a piece of the memory map that looked arbitrary in chapter 1.
The bank window sits *below* the IO page rather than at the top of memory, so
that switching banks can never swap a device register out from under a
program. If the window reached the top, a write to `mb` could disconnect the
display.

The gtx-16 specification is [`gtx-16.md`](../gtx-16.md), and it is a different
kind of document from the ones this book has leaned on: not the machine, but
one particular arrangement of hardware built on top of it.

## What you now know

The instruction set is sealed on purpose — it covers computation, which is the
same everywhere, and leaves everything else to a host. Two doors cross that
boundary: `int` is open-ended and host-defined, `sys` is a small fixed table
the VM implements because every host needs the same handful of services. The
compiler for the high-level language uses exactly that table, so both
languages reach the world the same way. And a console adds its own hardware
not through new instructions but by answering at addresses, which is why the
address space is laid out to keep those addresses safe from a bank switch.

One thing is left. You can write programs and measure them; the last chapter
is about reading one you did not write.
