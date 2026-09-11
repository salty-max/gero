# 2. Values and types

We are going to build a small piece of a role-playing game across this
book — a character, some stats, a fight. It starts here with two
numbers.

## Binding a value

```gero
def main()
  let hp = 30
  print hp
end
```

`let` introduces a name and gives it a value. Run it and you get `30`.

`let` bindings are **mutable**. This is legal:

```gero
def main()
  let hp = 30
  hp = hp - 12
  print hp
end
```

`18`. If you want a value that cannot change, say `const`:

```gero
def main()
  const MAX_HP = 30
  print MAX_HP
end
```

Assigning to a `const` is a compile error, not a convention. The
distinction is worth using: a reader who sees `const` knows they do
not have to go looking for where it changes.

## Types

`hp` above is an `i16` — a signed 16-bit integer, from -32768 to
32767. That is the default, and you did not have to say so. When you
want to be explicit, or when the default is not what you mean, annotate:

```gero
def main()
  let hp: i16 = 30
  let level: u8 = 7
  let alive: bool = true
  print hp
  print level
end
```

There are eight primitive types, and the whole list fits in a
paragraph. `i8` and `u8` are one byte. `i16` (spelled `int` if you
prefer) and `u16` are two. `char` is one byte holding an ASCII code —
`'A'` is 65. `bool` is one byte. `str` is a pointer to text. And
`fixed` is a number with a fractional part, which needs its own
section.

[`lang.md`](../lang.md) §3.1 has the exact ranges.

## Why the sizes are in the table

On a machine with 64 KB, the difference between one byte and two is
not pedantry. A party of eight characters with twelve stats each is
96 numbers; at `i16` that is 192 bytes, at `u8` it is 96. Neither is
much. Multiply it by a level's worth of monsters and it starts being
a decision.

You do not have to make that decision yet. `int` everywhere is a fine
way to write your first program, and the compiler will tell you when
a value does not fit. But the sizes are visible on purpose — this is
a machine where you can know what your data costs, and later chapters
will spend that knowledge.

## There are no floating-point numbers

None. No `float`, no `double`.

The VM is integer-only, so a floating-point type would have to be
emulated in software — hundreds of instructions for a multiply, on a
machine where you are counting them. Instead there is `fixed`:

```gero
def main()
  let rate: fixed = 1.5
  let damage: fixed = 12.0
  print damage * rate
end
```

`fixed` stores a number as two bytes: one for the whole part, one for
the fraction in 256ths. So it covers roughly -128.0 to +127.99, in
steps of about 0.004. Multiplying two of them is a handful of
instructions rather than a subroutine.

The trade is real and you should know its shape. `fixed` cannot hold
1000.5, and it cannot hold 0.1 exactly — 0.1 is not a whole number of
256ths, so you get the nearest one. For damage multipliers, movement
speeds and percentages it is the right tool. For anything needing more
range or exactness, integers and a chosen unit are better: store
tenths of a percent as an `int` and divide when you display.

Chapter 9 comes back to this with a worked case.

## Text

```gero
def main()
  let name: str = "Ryu"
  print name
end
```

A `str` is a pointer to null-terminated bytes — two bytes in your
variable, the characters themselves living elsewhere in the image.
String literals are baked into the program when it is compiled.

## Putting it together

Our character, so far:

```gero
def main()
  const MAX_HP = 30

  let name: str = "Ryu"
  let hp: i16 = MAX_HP
  let level: u8 = 1
  let crit_rate: fixed = 0.25

  print name
  print hp
  print level
  print crit_rate
end
```

Four values and a constant. Nothing decides anything yet — every run
prints the same four lines. That is the next chapter.

---

**Next:** [Control flow](03-control-flow.md) — making the program
choose.
