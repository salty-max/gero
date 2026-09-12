# 12. A cart, end to end

The program from the last ten chapters is no longer a collection of isolated
snippets. It is a small deterministic fight with state, decisions, repetition,
functions, a growable inventory, enum variants, class instances, modules,
fixed-point armor, tests, and a benchmark.

This chapter puts every final file in one place. Build it once as written, then
change one rule and make it yours.

## The project

Create this structure:

```text
fight/
  gero.toml
  src/
    fighter.gr
    items.gr
    main.gr
  tests/
    heal.gr
```

The manifest connects the source and test trees:

```toml
[package]
name = "fight"
version = "0.1.0"

[build]
entry = "src/main.gr"

[test]
include = ["tests/"]
```

## Fighters own hit-point rules

`src/fighter.gr` defines the entity used by the fight and the fixed-point armor
calculation:

```gero
class Fighter
  let name: str
  let hp: i16
  let max_hp: i16
  let power: i16

  def init(self, name: str, hp: i16, power: i16)
    self.name = name
    self.hp = hp
    self.max_hp = hp
    self.power = power
  end

  def alive(self) -> bool
    return self.hp > 0
  end

  def take_damage(self, amount: i16)
    self.hp -= amount
    if self.hp < 0
      self.hp = 0
    end
  end

  def heal(self, amount: i16)
    self.hp += amount
    if self.hp > self.max_hp
      self.hp = self.max_hp
    end
  end
end

def reduced_damage(power: i16, blocked: fixed) -> i16
  let remaining: fixed = 1.0 - blocked
  return ((power as fixed) * remaining) as i16
end
```

The class protects the upper and lower hit-point boundaries through methods.
`reduced_damage` remains a free function because it calculates a value from
its arguments without changing one particular fighter.

## Items carry their own data

`src/items.gr` defines every valid item kind:

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

def describe(item: Item) -> str
  match item
    case Item.Potion(_) => return "potion"
    case Item.Ether => return "ether"
  end
end
```

Both matches are exhaustive. If you add another variant, the compiler points
to both functions until you decide how that item behaves and how it is named.

## `main` coordinates one fight

`src/main.gr` imports the definitions and controls the turn sequence:

```gero
use Fighter from "./fighter"
use reduced_damage from "./fighter"
use Item from "./items"
use heal_from from "./items"

def main()
  let ryu = Fighter("Ryu", 30, 7)
  let ken = Fighter("Ken", 35, 10)
  let bag: Vec(Item) = Vec.new()
  bag.push(Item.Potion(6))
  let turn = 0

  while ryu.alive() and ken.alive()
    turn += 1
    ken.take_damage(ryu.power)
    print "turn $(turn): $(ken.name) has $(ken.hp) hp"

    if ken.alive()
      ryu.take_damage(reduced_damage(ken.power, 0.25))
    end

    if ryu.hp <= 10 and bag.len() > 0
      for item in bag
        ryu.heal(heal_from(item))
      end
      bag.clear()
      print "$(ryu.name) drinks a potion and has $(ryu.hp) hp"
    end
  end

  if ryu.alive()
    print "$(ryu.name) wins with $(ryu.hp) hp"
  else
    print "$(ken.name) wins with $(ken.hp) hp"
  end
end
```

Read the loop as a sequence of rules:

1. Both fighters must be alive to begin a turn.
2. Ryu attacks first and the program reports Ken's new state.
3. Ken attacks only if he survived.
4. Ryu uses the bag once his hit points reach ten or less.
5. After the loop, the surviving fighter is the winner.

The loop does not know how hit points are clamped or how an item's payload is
extracted. It delegates those rules to the functions and methods that own
them. `main` is responsible for order.

## Tests pin the boundaries

`tests/heal.gr` checks the rules most likely to fail at an edge:

```gero
use Fighter from "../src/fighter"
use reduced_damage from "../src/fighter"
use test

@test
def heal_caps_at_max()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(7)
  test.assert_eq(ryu.hp, 23)
  ryu.heal(15)
  test.assert_eq(ryu.hp, 30)
end

@test
def damage_stops_at_zero()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(40)
  test.assert_eq(ryu.hp, 0)
  test.assert_eq(ryu.alive(), false)
end

@test
def armor_reduces_damage()
  test.assert_eq(reduced_damage(10, 0.25), 7)
end

@bench
def bench_construct_and_take_damage()
  let ryu = Fighter("Ryu", 30, 7)
  ryu.take_damage(7)
end
```

Run the tests before building:

```bash
gero test
```

```text
running 3 tests
test heal_caps_at_max ... ok
test damage_stops_at_zero ... ok
test armor_reduces_damage ... ok

3 passed
```

A failed test means one of the stated rules no longer matches the program.
Resolve that disagreement before treating the cart as finished.

## Build and run

```bash
gero build
gero run out/debug/fight.gx
```

```text
turn 1: Ken has 28 hp
turn 2: Ken has 21 hp
turn 3: Ken has 14 hp
Ryu drinks a potion and has 15 hp
turn 4: Ken has 7 hp
turn 5: Ken has 0 hp
Ryu wins with 8 hp
```

Trace Ryu's state to check the result. Ken's power is 10, armor blocks 0.25,
and the fixed-point calculation truncates 7.5 to 7 damage. Ryu falls from 30
to 23, then 16, then 9. The potion restores 6, after which one final counter
attack leaves 8. Ken does not attack after reaching zero.

That trace is a manual model of the program. The tests automate smaller rules;
reading the full output checks that those rules compose into the intended
fight.

## Inspect and ship

A release build goes in its own directory. Select that profile in
`gero.toml`:

```toml
[build]
entry = "src/main.gr"
optimize = "release"
```

Then build and inspect the resulting cart:

```bash
gero build
gero info out/release/fight.gx
gero disasm out/release/fight.gx
```

The build profile belongs in the manifest because it is a property of the
project. Change it back to `debug`, or remove the line to use the default,
when you want the debug cart again.

`gero info` reports the image size, bytecode version, entry address, banks,
persistence, and whether debug symbols are present. `gero disasm` lets you
follow the machine instructions chosen for the source.

The `.gx` file is the shipped artifact. Tests and benchmark functions are
collected by their own build profiles and do not become part of the ordinary
cart. A compatible Gero host only needs the cart, not this source directory.

Source in. One file out. The file runs.

## Make it yours

A useful next change is small enough to understand and large enough to alter
the outcome. Try one of these:

- Add a second potion and change the inventory rule so only one item is used
  per turn.
- Give `Ether` a visible effect, then let the compiler locate every match that
  needs updating.
- Move the armor fraction into a field so each fighter can block a different
  amount.
- Add a test that proves a defeated fighter never attacks back.
- Change one damage rule, predict the winner on paper, then run the cart.

Programming is the loop you used throughout this book: form a model, express
it in source, run it, compare the result with the model, and revise either the
program or your understanding.

## What you learned

You began with `print` and finished with a multi-module cart. Along the way,
values represented state, control flow changed it, functions named rules,
collections grouped values, enums constrained alternatives, classes preserved
entity behavior, fixed point represented fractions, and tests made claims
repeatable.

The language is a tool for expressing those ideas. The ideas travel with you.
