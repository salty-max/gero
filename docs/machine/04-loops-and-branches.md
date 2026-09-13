# 4. Loops and branches

Both programs in the last chapter repeated themselves, and neither chapter
explained how. It is time to, because this is where a processor stops looking
like a calculator and starts looking like something that can compute anything
at all.

The machine has no notion of a loop, an `if`, or a condition. It has the cycle
from chapter 1 and one additional fact: some instructions write to the
instruction pointer. Everything else is built from that.

## A jump is an assignment to `ip`

The instruction pointer holds the address of the next instruction. Write to it
and the processor fetches from somewhere else — not because jumping is a
special operation, but because the next fetch reads whatever `ip` now says.

That is all `jmp` does. Its disassembly makes the point better than prose:

```text
0014:  90 04 00        jmp   &0004
```

An opcode and an address. The processor stores `$0004` into `ip`, the cycle
comes round, and the next fetch happens at `$0004` instead of `$0017`.
Jumping backwards costs exactly what jumping forwards costs, which is why a
loop is not more expensive than a straight line of the same instructions.

`jmp` alone gives you a loop that never ends. To get one that stops, the jump
has to be able to decline.

## What a comparison leaves behind

A conditional jump needs to know something about the values in play, and the
mechanism for that is the flags register. It works in two steps that are
worth keeping separate in your mind, because their separation is the design.

First, an instruction performs some arithmetic and records facts about the
result in `flg`: whether it was zero, whether its high bit was set, whether it
carried, whether it overflowed as a signed value. Then, later, a conditional
jump reads those bits and decides whether to jump.

The two steps are not joined. Nothing binds a comparison to the branch that
uses it, and any arithmetic instruction in between will overwrite what the
comparison recorded. That is a real hazard, and it is also what makes the
design flexible — you can compare once and branch on the result several times.

`cmp` exists for the first step. It subtracts its second operand from its
first, sets the flags from that subtraction, and throws the result away:

```asm
mov $0005, r1
cmp r1, $0003
```

`r1` still holds 5 afterwards. The subtraction happened only for its side
effects, which is a strange idea the first time you meet it and an obvious one
shortly after: what you want to know is the *relationship* between two values,
and subtraction is how a machine that can only add discovers it. If `a - b` is
zero they were equal. If it went negative, `a` was smaller.

This is why comparison and subtraction are the same operation on almost every
processor ever built, and why `cmp` is usually a `sub` that forgot to write
its answer down. [`isa.md` §2.1](../isa.md) lists which instructions set
which flags; the useful thing to remember is that `mov`, `push` and `pop`
leave them alone, so moving a value between registers will not destroy a
comparison you are about to branch on.

## A loop that finishes

Put the two steps together:

```asm
const PRINT = $10

main:
  mov '5', r1
.loop:
  int PRINT
  dec r1
  cmp r1, '0'
  jge .loop
  mov $0A, r1
  int PRINT
  hlt
```

```text
543210
```

Read the loop body as the machine does. `int PRINT` prints the character in
`r1`. `dec r1` lowers it by one, which — since the digits are consecutive in
the encoding, as chapter 2 established — moves it to the previous digit.
`cmp r1, '0'` records how `r1` now stands against the character zero. `jge
.loop` reads that record and jumps back if `r1` is still greater than or equal
to it.

When `r1` finally drops below `'0'`, the flags say so, `jge` declines, and
execution falls through to the two instructions that print a newline. Falling
through is not a mechanism; it is what happens when nothing writes to `ip`.

The disassembly shows the loop closed:

```text
0000:  10 35 00 02     mov   $0035, r1  ; entry point
0004:  FC 10           int   $10
0006:  49 02           dec   r1
0008:  80 02 30 00     cmp   r1, $0030
000C:  97 04 00        jge   &0004
000F:  10 0A 00 02     mov   $000A, r1
0013:  FC 10           int   $10
0015:  FF              hlt
```

`.loop` is `$0004` and the `jge` at `$000C` names it. The whole of the
repetition is that one backward address.

There is one detail in this program that is easy to miss and will eventually
matter. `dec` sets the zero, negative and overflow flags but deliberately
leaves carry untouched. That is not an oversight — it is a convention shared
with the 6502, Z80, 8086 and ARM, and it exists so that a loop counter can be
decremented in the middle of a sequence without destroying a carry the code
around it is still using. Small compatibilities like this are most of what an
instruction set inherits from its ancestors.

## Signed and unsigned are different questions

Now the part that produces real bugs.

The conditional jumps come in two families that look interchangeable and are
not. `jlt`, `jle`, `jgt` and `jge` answer the **signed** question, reading the
negative and overflow flags. `jcc` and `jcs` answer the **unsigned** question,
reading the carry flag.

The reason there are two is that a sixteen-bit register holds a bit pattern,
and a bit pattern does not know what it means. `$8000` is 32,768 if you are
counting upward from zero and −32,768 if the top bit means "negative". Both
readings are legitimate and they disagree about almost everything, so the
machine cannot pick one for you. It records enough in the flags to answer
either question and lets the branch you choose declare which question you were
asking.

You can watch them disagree:

```asm
const PRINT = $10

main:
  mov $8000, r1
  cmp r1, $0001
  jge .signed_ge
  mov 'L', r1
  int PRINT
  jmp .unsigned
.signed_ge:
  mov 'G', r1
  int PRINT
.unsigned:
  mov $8000, r1
  cmp r1, $0001
  jcs .unsigned_lt
  mov 'G', r1
  int PRINT
  hlt
.unsigned_lt:
  mov 'L', r1
  int PRINT
  hlt
```

```text
LG
```

The same comparison, of the same two values, twice. Read as signed, `$8000` is
−32,768 and is **less** than 1, so `jge` declines and the program prints `L`.
Read as unsigned it is 32,768 and is **greater**, so `jcs` — which jumps when
the first operand was below the second — also declines, and the program prints
`G`.

Getting this wrong is not a crash. It is a program that works on every value
you tested and fails on the ones above 32,767, which is the most expensive
kind of mistake because it survives review and ships. When you write a
comparison, decide deliberately which of the two questions you are asking.

The carry flag is the place people slip, so it is worth stating exactly. `cmp`
sets carry when the subtraction **borrowed**, which happens when the first
operand is below the second. So `C = 1` means less-than and `C = 0` means
greater-or-equal. Other processor families define carry the other way round on
subtraction, which is a good reason to check [`isa.md` §2.1](../isa.md) rather
than trust a habit formed elsewhere.

`jeq` and `jne` sit outside the argument. They read only the zero flag, and
two bit patterns are equal or not regardless of how you are reading them.

## The rest of the family

Two more instructions exist because the pattern above is common enough to
deserve shorter encodings.

`djnz` decrements a register and jumps if the result is not zero — the entire
tail of a counted loop in one instruction, inherited from the Z80. `jr` jumps
to a nearby address using a single signed byte of offset instead of a full
address, which saves a byte for branches within 127 bytes of where they sit.
Tight loops are usually well inside that.

Neither adds capability. Both exist because a loop is the thing programs spend
the most time doing, and an instruction set is partly a record of what its
users turned out to write most. The complete list of jumps, with the flag
condition each tests, is in [`isa.md` §5](../isa.md).

## What you now know

A jump writes to the instruction pointer, and that is the whole of control
flow. Comparison and branching are two separate steps joined only by the flags
register, which means arithmetic between them will destroy what you recorded.
`cmp` is a subtraction kept for its side effects, because subtraction is how a
machine discovers the relationship between two numbers. Signed and unsigned
comparisons are different questions with different instructions, and choosing
the wrong one produces a program that fails only on large values.

You can now write any computation that does not need to call a function: you
have values, memory, arithmetic, and decisions. What you cannot yet do is give
a piece of code a name, use it from two places, and have it return to whoever
asked. That needs somewhere to record where to come back to — which is the
stack, and the next chapter.
