# 8. Modules

The last example is long because one file defines items, fighters, inventory
behavior, and `main`. A program becomes easier to navigate when each part has
a clear home.

A `.gr` file is a **module**. Modules let us split a program without losing the
relationships between its parts.

## Create the project

Make this directory structure:

```text
fight/
  gero.toml
  src/
    fighter.gr
    items.gr
    main.gr
```

Each source file will own one responsibility. `fighter.gr` defines fighter
state and behavior. `items.gr` defines the possible items. `main.gr` connects
them and controls the fight.

## The fighter module

Put this in `src/fighter.gr`:

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
```

A module does not need a `main` function. It may exist to define names that
another module uses.

## The item module

Put this in `src/items.gr`:

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
```

Everything declared at the top level is exported by default. Prefix a helper
with `local` when it should remain an implementation detail of its module.

## Importing names into `main`

Put this in `src/main.gr`:

```gero
use Fighter from "./fighter"
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
      ryu.take_damage(ken.power)
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

Each `use` brings one exported name into this module. The path begins with
`./`, so it is resolved relative to `main.gr`; the `.gr` extension is omitted.
Import paths are case-sensitive on every platform. If the file is
`fighter.gr`, writing `"./Fighter"` is an error even on a filesystem that
would otherwise accept it.

The source is split, but compilation still follows the imports and checks the
program as a whole. `main.gr` can call the methods on `Fighter` and pass `Item`
values because it imported those definitions.

## Describing the project

Create `gero.toml` at the project root:

```toml
[package]
name = "fight"
version = "0.1.0"

[build]
entry = "src/main.gr"
```

The manifest gives the project a name and tells the build command where
execution begins. From the `fight` directory, run:

```bash
gero build
gero run out/debug/fight.gx
```

The fight now plays several turns:

```text
turn 1: Ken has 28 hp
turn 2: Ken has 21 hp
Ryu drinks a potion and has 16 hp
turn 3: Ken has 14 hp
turn 4: Ken has 7 hp
Ken wins with 7 hp
```

`gero build` starts from `[build].entry`, follows the imported modules, and
writes `out/debug/fight.gx`. The output directory names the build profile;
`debug` is the default. Setting `optimize = "release"` in the manifest's
`[build]` section makes `gero build` write `out/release/fight.gx` instead.

The program is now large enough to benefit from modules, but the split did not
change its behavior. That is the purpose of organization: reduce the amount a
reader must hold in mind at once while preserving the program's meaning.

Ryu still loses. Ken's ten points of power become ten points of damage because
the fight has no armor rule. A quarter of each hit should be blocked, which
requires a fractional calculation.

## What you learned

A module gives related definitions a file and a namespace boundary. `use`
imports selected names, relative paths connect neighboring source files, and
a manifest identifies the project and its entry point. The compiler follows
those connections to produce one cart.

---

**Next:** [Numbers that are not integers](09-fixed.md) — representing a
quarter without floating point.
