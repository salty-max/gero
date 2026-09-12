# 11. Reaching the machine

Gero lets us describe the fight in terms of fighters, items, and rules. The
cart still runs as machine instructions. Most programs should let the compiler
choose those instructions, but a small-machine language is more useful when
the boundary remains visible.

This chapter introduces three ways to reach that boundary. They are specialized
tools, not requirements for ordinary Gero programs.

## Read what the compiler produced

Build the fight and disassemble its cart:

```bash
gero build
gero disasm out/debug/fight.gx
```

The output is assembly. You will see labels for functions, operations on
registers, jumps implementing the loop, and calls into the small runtime. The
Gero source is not stored there: the compiler has translated its meaning into
the VM's instruction set.

Disassembly answers concrete questions. Did this function become a call? How
large is the loop? Which instructions account for a benchmark result? You do
not need to read every line. Begin by finding a function name you recognize
and following the instructions until its return.

The Gero Machine teaches that language from the beginning. For now,
disassembly is evidence that the high-level program and machine execution are
two views of the same cart.

## Insert one instruction with `asm`

Occasionally the VM has an operation that Gero cannot express directly.
`asm "..."` inserts one assembly instruction into a function:

```gero
def main()
  asm "nop"
  print "still here"
end
```

`nop` means “no operation.” The machine spends one instruction cycle and then
continues. It is a deliberately boring first example because it isolates the
mechanism: control enters the inline instruction and returns immediately to
compiled Gero.

A practical use is controlling whether interrupts may run:

```gero
def main()
  asm "cli"
  print "critical work"
  asm "sei"
end
```

`cli` clears the interrupt-enable flag and `sei` sets it again. The statements
between them form a **critical section**, where an interrupt handler cannot
observe half-finished state.

The escape hatch is intentionally narrow. One `asm` statement contains one
instruction. It cannot define a label or hide a jump. Locals may be inserted
with the `{name}` form when an instruction accepts their value; register-only
instructions still name registers directly. The complete operand rules belong
to [`lang.md`](../lang.md#411-inline-assembly), and instruction behavior
belongs to [`isa.md`](../isa.md#5-instruction-set).

Inline assembly bypasses some of the compiler's understanding. Use it when you
can name the instruction you need and explain why the language cannot express
the operation.

## Put code in a bank

The VM can address 64 KB at once, but a cart may contain additional **banks**.
A bank is a region of cart data that can be mapped into a window of the
address space when needed. This lets a large cart hold more than fits in the
machine at one moment.

Gero can place a declaration in a bank:

```gero
@bank 1
def banked_message()
  print "hello from bank 1"
end

def main()
  banked_message()
end
```

The `@bank 1` annotation is information for the compiler. A call from another
bank goes through generated code that changes the mapping, calls the function,
and restores the previous mapping. The source still reads as a function call.

Banking trades simplicity for capacity. Code that crosses banks performs more
work, and data is only directly reachable while its bank is mapped. Use it
when the cart has actually grown beyond the base image; [`isa.md`](../isa.md#32-banks)
owns the memory-map rules.

## Respond to an interrupt

Normal control flow moves because the current statement chooses the next one.
An **interrupt** begins because the machine or its host reports an event: a
frame started, a timer fired, or a device needs attention.

`@interrupt N` associates a function with one interrupt vector:

```gero
let frame_count: i16 = 0

@interrupt $07
def on_vblank()
  frame_count += 1
end

def main()
  print frame_count
end
```

The handler takes no parameters and returns no value. The compiler creates the
entry and return sequence required by the VM. A fantasy-console host can fire
vector `$07` when a frame begins.

`gero run` does not generate that event, so this standalone example prints
zero. The code demonstrates registration; observing the count change requires
a host that provides vblank.

Interrupt handlers can run between ordinary instructions, so they make shared
state harder to reason about. Keep them short, avoid work that can allocate,
and move the larger response into the normal program loop. The exact entry,
masking, and return rules live in [`isa.md`](../isa.md#6-interrupts).

## What you learned

Disassembly reveals the instructions selected by the compiler. Inline assembly
inserts one operation the language cannot express. Banks expand cart capacity
through a mapped memory window, and interrupts let outside events redirect
execution to a handler. These tools cross abstraction boundaries, so their
costs and assumptions must remain explicit.

---

**Next:** [A cart, end to end](12-a-cart.md) — put every part of the fight in
place and ship the resulting image.
