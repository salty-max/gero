# 2. Values and types

A program becomes useful when it can remember information. In a role-playing
fight that information includes a character's name, hit points, power, and
whether the character can still act.

We will build that fight across this book. It starts with one number.

## Names for values

```gero
def main()
  let hp = 30
  print hp
end
```

The program prints:

```text
30
```

`30` is a **value**. `hp` is a name bound to that value, and `let` creates the
binding. After the first line inside `main`, the program can say `hp` wherever
it needs the current hit-point value.

Names matter because they attach meaning to data. Compare `print 30` with
`print hp`. The machine receives a number either way, but a reader can tell
what `hp` represents.

## State changes over time

The information a program remembers at a particular moment is its **state**.
When the fighter takes 12 damage, the state changes:

```gero
def main()
  let hp = 30
  hp = hp - 12
  print hp
end
```

The assignment `hp = hp - 12` works from right to left. First the program reads
the current value of `hp`, subtracts 12, and obtains 18. Then it stores 18 back
under the name `hp`. The old value is replaced.

```text
18
```

Bindings created with `let` are **mutable**, which means their value may
change. Mutation is how a program records that time has passed: damage was
taken, a turn ended, or an item was used.

Some values describe a rule rather than changing state. Use `const` for those:

```gero
def main()
  const MAX_HP = 30
  let hp = MAX_HP
  hp -= 12
  print hp
end
```

`hp -= 12` is a shorter spelling of `hp = hp - 12`. `MAX_HP` remains 30 for
the whole run.

The following program deliberately does not compile:

```gero
def main()
  const MAX_HP = 30
  MAX_HP = 40
end
```

The compiler reports the binding by name:

```text
error: cannot assign to const `MAX_HP` [E_TYPE_ASSIGN_CONST]
```

This is more than a naming convention: once the source says `const`, both the
compiler and every reader can rely on the value staying fixed.

## A type describes possible values

Every value has a **type**. A type tells the compiler what a value can
represent and which operations make sense for it. Adding two integers makes
sense. Subtracting a fighter's name from its hit points does not.

Gero infers that `30` is an `i16`, its default integer type. You can write the
type explicitly after the name:

```gero
def main()
  let hp: i16 = 30
  let level: u8 = 7
  let alive: bool = true
  let name: str = "Ryu"

  print hp
  print level
  print alive
  print name
end
```

The annotation in `hp: i16` says that `hp` can hold a signed 16-bit integer.
The compiler checks the initial value and every later assignment against that
promise.

The primitive types fit in a short table:

| Type | What it represents | Size |
|---|---|---:|
| `i8` | integers from -128 through 127 | 1 byte |
| `u8` | integers from 0 through 255 | 1 byte |
| `i16` or `int` | integers from -32768 through 32767 | 2 bytes |
| `u16` | integers from 0 through 65535 | 2 bytes |
| `bool` | `true` or `false` | 1 byte |
| `char` | one ASCII character such as `'A'` | 1 byte |
| `str` | a reference to text | 2 bytes plus the text |
| `fixed` | a number with a fractional part | 2 bytes |

Signed types can represent negative values. Unsigned types spend the same
number of bits on a larger non-negative range. `i16` is a good default while
learning; choose a narrower or unsigned type when its range expresses a real
rule in the program.

## Size is part of the design

On a machine with 64 KB, one byte versus two is visible. An array containing
96 `i16` values occupies 192 bytes. The same number of `u8` values occupies 96
bytes.

That does not mean that the smaller type always wins. If a hit-point value may
grow past 255 or fall below zero during damage calculation, `u8` cannot
represent every intermediate state. Saving one byte and losing a necessary
value is a bad trade.

Types are choices about meaning first and storage second.

## Text and fractional numbers

A `str` value refers to null-terminated text stored elsewhere in the cart:

```gero
def main()
  let name: str = "Ryu"
  print "fighter: $(name)"
end
```

The variable itself occupies two bytes because it stores the address of the
text. The characters in `"Ryu"` occupy their own bytes in the image. The
`$(name)` inside the larger string asks Gero to insert the value of `name`.

The VM has no floating-point instructions, so Gero has no `float` or `double`
type. It provides `fixed`, a small fixed-point number, for values such as
movement speeds and damage multipliers. We will use it in chapter 9, after the
fight gives us a real fractional calculation to make.

## The fighter's first state

```gero
def main()
  const MAX_HP = 30

  let name: str = "Ryu"
  let hp: i16 = MAX_HP
  let power: i16 = 7
  let alive: bool = hp > 0

  print name
  print hp
  print power
  print alive
end
```

This state is still passive. Every run prints the same values because the
program makes no decisions and repeats no work. Those are the next two tools.

## What you learned

A value is data; a binding gives it a meaningful name. Mutable state changes
as the program runs, while a constant records a rule that cannot be assigned
to. A type defines which values and operations are valid, and on this machine
it also makes storage costs explicit.

---

**Next:** [Control flow](03-control-flow.md) — making the program choose and
repeat.
