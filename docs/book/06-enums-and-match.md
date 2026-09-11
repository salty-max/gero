# 6. Enums and `match`

A potion is not an `i16`. It is one of a small set of things a bag
can hold, and some of those things carry extra data. That is an
**enum**.

```gero
enum Item
  case Potion(amount: i16)
  case Ether
  case Phoenix
end

def main()
  let p = Item.Potion(15)
  let e = Item.Ether
  print "ok"
end
```

`ok`. `Item.Potion(15)` constructs a value whose variant is `Potion`
and whose payload is `15`. `Ether` and `Phoenix` carry nothing. The
slot is sized for the largest variant — here the `i16` on `Potion` —
plus a tag byte that says which one it is.

## Asking which

`is` tests the tag and does not bind the payload:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
end

def main()
  let item = Item.Potion(15)
  if item is Item.Potion
    print "drink"
  end
end
```

`drink`.

To get the `15` out, **`match`**:

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
    case Item.Phoenix => return "phoenix"
  end
end

def main()
  print describe(Item.Potion(15))
end
```

`potion`. The `_` in `Potion(_)` means we do not need the amount
here. When we do:

```gero
enum Item
  case Potion(amount: i16)
  case Ether
  case Phoenix
end

def heal_from(item: Item) -> i16
  match item
    case Item.Potion(n) => return n
    case Item.Ether => return 0
    case Item.Phoenix => return 0
  end
end

def main()
  print heal_from(Item.Potion(15))
end
```

`15`. `n` is bound only in that arm.

## Exhaustiveness

Leave a variant out and the compiler stops you. That is the feature.

```
error: non-exhaustive match on enum `Item` — missing variant: Phoenix [E_MATCH_NON_EXHAUSTIVE]
```

A `match` on an enum is a promise that every shape was considered.
A missing arm is a bug you have not hit yet. Adding `Phoenix` to
`Item` turns every incomplete `match` red, which is the point.

`bool` is closed the same way — both `true` and `false`, or a
wildcard. Integers and strings are not a closed set; a missing arm
there is not a compile error.

`case _ =>` is the wildcard. Use it when the rest of the variants
share a behaviour, not to silence a warning you have not read.

## Putting a potion in the fight

```gero
enum Item
  case Potion(amount: i16)
  case Ether
  case Phoenix
end

def heal_from(item: Item) -> i16
  match item
    case Item.Potion(n) => return n
    case Item.Ether => return 0
    case Item.Phoenix => return 0
  end
end

def main()
  let hp: i16 = 23
  let item = Item.Potion(15)
  hp += heal_from(item)
  print hp
end
```

`38`. The bag from chapter 5 can wait until the drinker is a single
value too. That is a class.

---

**Next:** [Classes](07-classes.md) — Ryu as one thing, not four
variables.
