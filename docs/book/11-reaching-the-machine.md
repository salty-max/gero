# 11. Reaching the machine

Most of a cart is Gero. A few instructions are not, because the
compiler will not emit them, or because you have counted the
cycles and you disagree with it.

## One instruction

`asm "..."` drops a single bytecode instruction into a Gero
function. One, not a block. Chain them if you need two.

```gero
def main()
  asm "cli"
  print 1
  asm "sei"
end
```

`1`. `cli` clears the interrupt flag; `sei` sets it. Together they
are a window in which a handler will not run. The compiler does
not spell those, because most programs never need the window.

A local can be named inside the string with `{x}`. The compiler
checks that `x` exists and that the instruction will take it. A
register-only instruction still wants a register:
`asm "swap r1, r2"`, not `{x}`.

There are no labels, no `jmp`, no second instruction hiding in the
quotes. That is the bridge from the addendum: one mnemonic when
you have to, then back.

## A bank, a handler

`@bank N` on a declaration puts that function or data in bank `N`
of the cart. Calls from elsewhere go through a trampoline the
compiler emits. You write the annotation; you do not write the
`mb`.

```gero
@bank 1
def in_bank()
  print 1
end

def main()
  in_bank()
end
```

`1`.

`@interrupt N` binds a function to vector `N`. The body takes no
parameters and returns nothing. The compiler saves and restores
the registers a handler must not clobber, emits `rti`, and writes
the address into the vector table at boot.

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

`0` — nothing in `gero run` fires vblank, so the counter stays
put. On a console, `$07` is the start of a frame. The function is
installed either way.

## The other book

None of this is the advanced course. It is the other language, on
the same machine, producing the same `.gx`.

**The Gero Machine** teaches that language: registers, the memory
map, `cmp` and the jumps, the stack, the IVT, banking by hand,
SRAM, counting cycles on a loop you wrote. Start there if what you
wanted was to know what the CPU is doing. Start here if what you
wanted was to make something. They are peers. This chapter is the
doorway, not the prerequisite.

---

**Next:** [A cart](12-a-cart.md) — the fight, shipped.
