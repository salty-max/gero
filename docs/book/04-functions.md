# 4. Functions

Chapter 3 ended with a fight loop that had the damage number wedged
inside it. Let us give the pieces names.

## Declaring one

```gero
def damage_from(power: i16, defense: i16) -> i16
  return power - defense
end

def main()
  print damage_from(12, 5)
end
```

`7`.

`def` opens it, `end` closes it. Each parameter is annotated with its
type — that is required, not optional. The `-> i16` after the
parameters is the return type.

A function that returns nothing simply omits the arrow:

```gero
def announce(name: str)
  print name
end

def main()
  announce("Ryu")
end
```

## Why the annotations are mandatory

Inside a function, `let hp = 30` infers its type happily. At the
boundary, you must say. That asymmetry is deliberate: the signature is
what a caller reads, and a caller should not have to read the body to
know what to pass.

It also means an error lands where the mistake is. Call
`damage_from("Ryu", 5)` and the compiler objects at that line, rather
than somewhere inside the subtraction.

## Returning more than one thing

Some questions have two answers. Did the attack land, and for how
much? gero-lang has no exceptions and no `Result` type; a function
that answers two things returns two things:

```gero
def attack(power: i16, defense: i16, roll: i16) -> (bool, i16)
  if roll < 20
    return (false, 0)
  end
  return (true, power - defense)
end

def main()
  let (hit, dmg) = attack(12, 5, 75)
  if hit
    print dmg
  else
    print "miss"
  end
end
```

`7`. The `let (hit, dmg) = ...` destructures the returned pair into
two bindings.

This is the Go shape rather than the Rust one, and
[`gero-lang.md`](../gero-lang.md) §9 says why: a `Result` type wants
generics and a propagation operator, and both cost more than they are
worth on a machine this size. An explicit check at the call site is
the trade.

## The fight, rewritten

```gero
const MAX_HP = 30

def severity(hp: i16) -> str
  if hp <= 0
    return "fallen"
  else if hp < MAX_HP / 4
    return "critical"
  else if hp < MAX_HP / 2
    return "wounded"
  end
  return "healthy"
end

def attack(power: i16, defense: i16, roll: i16) -> (bool, i16)
  if roll < 20
    return (false, 0)
  end
  return (true, power - defense)
end

def main()
  let hp = MAX_HP
  let turn = 0

  while hp > 0
    turn += 1
    let (hit, dmg) = attack(12, 5, 75)
    if hit
      hp -= dmg
    end
    print severity(hp)
  end

  print turn
end
```

`MAX_HP` moved out of `main` to the top level, where both functions can
see it. A top-level `const` is visible to everything in the file.

Every piece is now named and testable on its own. `severity` does not
know about the fight; `attack` does not know about hit points. That is
what makes chapter 10's tests possible, and what makes it reasonable
to add a second character in chapter 5.

## Recursion works

```gero
def fib(n: i16) -> i16
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end

def main()
  print fib(10)
end
```

`55`. Each call gets its own frame on the stack. Chapter 5 of
[The Gero Machine](../machine/README.md) shows what a frame actually
is; here it is enough to know the depth is bounded by memory, and 64
KB is not a lot of it.

---

**Next:** chapters 5 onward — collections, enums and `match`, classes,
modules. The character stops being four loose variables and starts
being a thing.
