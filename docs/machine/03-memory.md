# 3. Memory

Registers run out. That is not a flaw to work around; it is the premise the
whole design rests on. Eight general-purpose registers hold eight values, and
the ninth value you need has to live somewhere else and come back when it is
wanted.

That somewhere is memory, and this chapter is about reaching it: the ways an
instruction can name an address, why there is more than one way, how to attach
names to places, and how to put data into a program in the first place.

## Storing and loading

The instruction that moves values between registers also moves them between
registers and memory. What changes is how the operand is written.

```asm
mov $0041, r1
mov r1, &0040
mov $0000, r1
mov &0040, r1
```

The `&` prefix means "the memory at this address" rather than the address
itself. So the second line stores `r1` into address `$0040`, and the fourth
loads it back. Between them the third line wipes `r1`, so that if the load
failed we would see it.

Source-first ordering makes these read consistently once you trust it. `mov
r1, &0040` moves *from* the register *to* the memory; `mov &0040, r1` moves
the other way. The `&` tells you which operand is an address, and the position
tells you which direction the value travels.

This pair — store a value, do something else, load it back — is the whole of
what memory offers. Everything else in this chapter is about saying *which*
address, more conveniently or more cheaply.

## Why there is more than one way to name an address

Assemble a program that touches two different addresses and the reason becomes
visible immediately:

```asm
mov $0041, r1
mov r1, &0040
mov r1, &2620
mov &0040, r2
mov &2620, r3
```

```text
0000:  10 41 00 02     mov   $0041, r1  ; entry point
0004:  19 02 40        mov   r1, &40
0007:  12 02 20 26     mov   r1, &2620
000B:  1A 40 03        mov   &40, r2
000E:  13 20 26 04     mov   &2620, r3
0012:  FF              hlt
```

The two stores are the same operation on different addresses, and they
assembled to different opcodes and different lengths. Storing to `$0040` took
three bytes; storing to `$2620` took four. The loads show the same gap.

The reason is the one chapter 1 raised. `$0040` is in the **zero page**, the
first 256 bytes of memory, and an address in that range fits in a single byte.
An instruction reaching there does not need to carry sixteen bits of address,
so the instruction set provides a separate, shorter opcode for exactly that
case, and the assembler selects it when it can see that your address qualifies.

A byte per access sounds like nothing. It is nothing, once. The point is that
this is an *access* cost, not a storage cost: it applies every time the
instruction appears, and the values a program touches most are the ones it
touches in loops. Putting a frequently used variable in the zero page and a
rarely used one above it is one of the oldest size optimisations there is, and
it costs nothing but the decision about where to put things.

This is also your first look at what an **addressing mode** actually is. It is
not a feature of memory; memory is a flat array and every byte in it is
reachable. An addressing mode is a way of *writing down* which byte you mean,
and a machine offers several because different ways of saying it cost
different amounts and suit different situations. The zero-page mode is the
cheap one for a small range. The next one is for a case the first cannot
express at all.

## Addresses computed while the program runs

Both forms so far have the address fixed in the instruction. That is fine for
a variable, and useless for anything with a position that varies — a
character partway through some text, an entry partway down a table. The
address you want is not known when you write the program, only when it runs.

For that, an instruction can take its address from a register, optionally with
an offset added:

```asm
; fragment: shown in context in the next program
mov8 [@NAME + r3], r1
```

`@NAME` is the address a label stands for and `r3` holds a number, so the
address read is the sum of the two, computed fresh each time the instruction
executes. Change `r3` and the same instruction reaches somewhere else. This is
**indexed addressing**, and it is what makes it possible to write one
instruction that walks a whole structure.

`mov8` is the byte-sized form of `mov`. Registers are sixteen bits, so the
ordinary `mov` moves two bytes at a time; text is stored one byte per
character, and reading a character with a two-byte load would pick up its
neighbour as well. `mov8` reads a single byte and puts it in the low half of
the register, clearing the top. The complete list of operand forms and the
sizes each supports is [`asm.md` §3](../asm.md).

## Putting data in the program

A program that works on data needs that data to exist somewhere. The `data8`
directive places bytes directly into the image:

```asm
const PRINT = $10

main:
  mov $0000, r3
.next:
  mov8 [@NAME + r3], r1
  cmp r1, $00
  jeq .done
  int PRINT
  inc r3
  jmp .next
.done:
  hlt

data8 NAME = "gero", $00
```

```text
gero
```

The last line reserves space for the text `gero` followed by a zero byte, and
gives that position the name `NAME`. The zero is not decoration. Nothing
records how long the text is, so the program needs some way to know when to
stop, and the convention here is to mark the end with a value that cannot
occur inside it. Text terminated this way is called **null-terminated**, and
the cost of the convention is exactly the loop you see: read a byte, check it
for zero, act on it, advance.

The loop itself is the subject of the next chapter. What matters here is the
addressing. `r3` starts at zero and `inc r3` raises it by one each pass, so
`[@NAME + r3]` reads `NAME`, then `NAME + 1`, then `NAME + 2`. One instruction
reads every character in turn because the address it names is computed rather
than fixed.

## What labels actually are

Disassembling that program shows what the assembler did with the names:

```text
0000:  10 00 00 04     mov   $0000, r3  ; entry point
0004:  25 18 00 04 02  mov8  [NAME + r3], r1
0009:  80 02 00 00     cmp   r1, $0000
000D:  92 17 00        jeq   &0017
0010:  FC 10           int   $10
0012:  48 04           inc   r3
0014:  90 04 00        jmp   &0004
0017:  FF              hlt
0018:                  data8 NAME = $67, $65, $72, $6F, $00  ; "gero"
```

Every name is gone. `.done` became `&0017`, `.next` became `&0004`, and
`NAME` became `$0018` inside the `mov8` — the `18 00` in its bytes, little end
first. The machine never sees a label. A label is a promise the assembler
makes to itself: remember where this line landed, and substitute that address
wherever the name is used.

That is why labels matter more here than names do in a high-level language.
Addresses shift whenever anything before them changes size. Insert one
instruction near the top of this program and every address after it moves, and
any that you had written by hand would now be wrong — silently wrong, because
a number is a valid address whether or not it is the one you meant. Labels
remove the entire class of mistake by making the assembler recompute the
addresses on every build.

The names beginning with a dot are **local labels**, scoped to the enclosing
top-level label. It is the same mechanism with a smaller namespace, and it
exists so that every loop in a program can call its own start `.next` without
collisions. The scoping rules are in [`asm.md` §2.1](../asm.md).

Look at the last line too, because it settles something from chapter 2. The
text `gero` is stored as `$67, $65, $72, $6F, $00` — five ordinary bytes. The
disassembler prints `"gero"` beside them as a courtesy to you, having noticed
they are all printable. In the image there is nothing but numbers. A string is
a region of memory and an agreement about how to read it, and here you have
written both halves yourself.

## Where things sit

Notice the address the data landed at: `$0018`, immediately after `hlt` at
`$0017`. The assembler laid out this program by writing each item after the
last, code and data alike, in the order they appear in the source.

This is the **flat image model**, and it follows from the machine having no
opinion about the difference between code and data. The `data8` directive does
not put the bytes in a data section, because there is no data section. It puts
them next, and they are only data because nothing ever jumps to them.

Which means the placement is yours to get right. Put a `data8` in the middle
of a function and the processor will execute your text as instructions when it
reaches it. There is no error for this; the bytes decode as something, and the
machine does whatever that something is. Data goes after the code that uses
it, past a `hlt` or an unconditional jump, and the reason is not style. The
layout rules, including how to place things at chosen addresses, are in
[`asm.md` §4](../asm.md).

## What you now know

Memory is reached with the same `mov` that moves values between registers,
with `&` marking an operand as an address. An address can be written three
ways, and the choice is about cost and expressiveness rather than capability:
the zero page trades range for a byte of encoding, a full address buys the
whole space, and an indexed address buys the ability to compute the location
while the program is running. Labels are addresses the assembler works out for
you, which is what keeps a program correct when it changes shape. Data is laid
into the image alongside code, distinguished only by the fact that nothing
jumps to it.

Both example programs in this chapter contained a loop, and neither chapter
has explained one. That is next: what a flag is, what `cmp` really does, and
how a machine with nothing but a fetch cycle manages to make a decision.
