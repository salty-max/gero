# 6. Enums and `match`

A potion is not an `i16`.

We could assign every item a number—1 for a potion, 2 for ether—and store its
extra data somewhere else. That representation depends on the programmer
remembering the code and keeping several values consistent. The compiler sees
ordinary integers and cannot tell whether item 9 is impossible or simply new.

An **enum** defines a closed set of valid alternatives and gives each one a
name.

## Defining alternatives

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def main()
  let potion = Item.Potion(6)
  let ether = Item.Ether
  print potion
  print ether
end
```

`Item` is the type. `Potion` and `Ether` are its **variants**. An `Item` value
is exactly one of those variants at a time.

`Item.Potion(6)` constructs the `Potion` variant and carries 6 as its
**payload**. The payload lets the same variant represent potions of different
strengths. `Item.Ether` carries no extra information, so it needs no
parentheses.

The machine stores a small tag saying which variant is present, followed by
enough space for the largest payload. That implementation matters for size;
the programming benefit comes first: invalid item kinds are no longer values
of the type.

## Testing a variant

Use `is` when the decision only needs the tag:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def main()
  let item = Item.Potion(6)
  if item is Item.Potion
    print "this item can heal"
  end
end
```

The condition is true because `item` contains the `Potion` variant. `is` does
not extract the amount. It answers one Boolean question: is this that variant?

## Extracting a payload with `match`

When behavior depends on the variant and its payload, use `match`:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def heal_from(item: Item) -> i16
  match item
    case Item.Potion(amount) => return amount
    case Item.Ether => return 0
  end
end

def main()
  print heal_from(Item.Potion(6))
  print heal_from(Item.Ether)
end
```

`match` compares the value with each pattern. For a potion, the name `amount`
is bound to its payload inside that arm. For ether, there is no payload to
bind. The function returns 6 and then 0.

If an arm needs to recognize a payload without using it, `_` ignores that
position:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def describe(item: Item) -> str
  match item
    case Item.Potion(_) => return "potion"
    case Item.Ether => return "ether"
  end
end

def main()
  print describe(Item.Potion(6))
end
```

## Exhaustiveness turns change into an error

Suppose the program gains a third item:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
  case Phoenix
end
```

A match that only handles `Potion` and `Ether` deliberately fails to compile:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
  case Phoenix
end

def describe(item: Item) -> str
  match item
    case Item.Potion(_) => return "potion"
    case Item.Ether => return "ether"
  end
end
```

```text
error: non-exhaustive match on enum `Item` — missing variant: Phoenix [E_MATCH_NON_EXHAUSTIVE]
```

The compiler knows the complete set of variants because the enum declaration
closed it. Adding a variant therefore locates every decision that has not yet
accounted for the new possibility.

That is the feature.

A wildcard arm, `case _ =>`, matches anything not handled earlier. Use it when
the remaining variants truly share behavior. Listing every variant is better
when each new one should force a conscious decision.

## A bag of actual items

The vector from chapter 5 can now say what it contains:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def heal_from(item: Item) -> i16
  match item
    case Item.Potion(amount) => return amount
    case Item.Ether => return 0
  end
end

def main()
  let hp = 9
  let bag: Vec(Item) = Vec.new()
  bag.push(Item.Potion(6))
  bag.push(Item.Ether)

  for item in bag
    hp += heal_from(item)
  end

  print hp
end
```

The output is 15. The vector guarantees that every element is an `Item`; the
enum guarantees that every item has a valid variant and payload; the match
turns each variant into behavior.

The hit-point binding can still grow beyond its maximum. The data and the
operations that preserve its rules need to belong together.

## What you learned

An enum models a value that can have one of several known shapes. A variant
names a shape, a payload carries the data specific to it, and `match` selects
behavior while binding that data. Exhaustive matching lets the compiler turn
an unhandled program change into a precise error.

---

**Next:** [Classes](07-classes.md) — keeping a fighter's state and rules
together.
