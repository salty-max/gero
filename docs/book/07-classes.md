# 7. Classes

The fight now has a name, hit points, a maximum, and power. These values belong
to the same fighter, but loose bindings do not express that relationship. They
also allow impossible state: any part of the program can heal past the maximum
or leave hit points below zero.

A **class** defines a kind of value together with the operations that maintain
its rules.

## Defining a class and constructing an instance

Start with two fields:

```gero
class Fighter
  let name: str
  let hp: i16

  def init(self, name: str, hp: i16)
    self.name = name
    self.hp = hp
  end
end

def main()
  let ryu = Fighter("Ryu", 30)
  print ryu.name
  print ryu.hp
end
```

`class Fighter` opens the definition. The two `let` lines declare **fields**:
every `Fighter` instance stores its own `name` and `hp`.

`Fighter("Ryu", 30)` constructs an **instance** and calls its `init` method.
Inside a method, `self` refers to the particular instance receiving the call.
The assignments therefore mean “put this name and these hit points into the
new fighter.”

After construction, `ryu.name` and `ryu.hp` select fields on that instance.
The dot reads as belonging: this fighter's name, this fighter's hit points.

## Methods keep rules beside the data

Hit points have two rules: damage cannot leave them below zero, and healing
cannot raise them above the fighter's maximum. Methods give those changes one
controlled path:

```gero
class Fighter
  let name: str
  let hp: i16
  let max_hp: i16

  def init(self, name: str, hp: i16)
    self.name = name
    self.hp = hp
    self.max_hp = hp
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

def main()
  let ryu = Fighter("Ryu", 30)
  ryu.take_damage(7)
  print ryu.hp
  ryu.heal(15)
  print ryu.hp
end
```

The output is 23 and then 30. Calling `ryu.take_damage(7)` binds `self` to
`ryu` and `amount` to 7. Calling `ryu.heal(15)` uses the same instance, so it
sees the 23 left by the earlier method.

This is **encapsulation**: putting data beside the behavior that gives it
meaning. Gero does not make fields private, so the compiler will still permit
`ryu.hp = 1000`. The class creates a clear place for the rule and a method that
callers can use consistently.

## Methods can answer questions

A method follows the same return rules as any other function:

```gero
class Fighter
  let hp: i16

  def init(self, hp: i16)
    self.hp = hp
  end

  def alive(self) -> bool
    return self.hp > 0
  end
end

def main()
  let fighter = Fighter(7)
  print fighter.alive()
end
```

`alive` needs no argument after `self` because the answer comes from the
instance's own state. The method gives the condition a name, so a fight loop
can say `while ryu.alive() and ken.alive()` instead of repeating comparisons.

## Class instances have identity

Two fighters with the same field values are still two distinct instances:

```gero
class Fighter
  let hp: i16

  def init(self, hp: i16)
    self.hp = hp
  end

  def take_damage(self, amount: i16)
    self.hp -= amount
  end
end

def main()
  let first = Fighter(30)
  let second = Fighter(30)
  first.take_damage(7)
  print first.hp
  print second.hp
end
```

Only `first` changes, so the program prints 23 and then 30.

A class binding holds a reference to its instance. Passing that binding to a
function copies the reference, not all the fields. Both references reach the
same fighter:

```gero
class Fighter
  let hp: i16

  def init(self, hp: i16)
    self.hp = hp
  end

  def heal(self, amount: i16)
    self.hp += amount
  end
end

def drink(fighter: Fighter, amount: i16)
  fighter.heal(amount)
end

def main()
  let ryu = Fighter(9)
  drink(ryu, 6)
  print ryu.hp
end
```

The program prints 15. The parameter inside `drink` and the binding in `main`
refer to the same instance. This shared identity is useful for game entities,
but it also means a function can change an object its caller still uses.

## Bringing the fighter and bag together

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

def main()
  let ryu = Fighter("Ryu", 30, 7)
  let bag: Vec(Item) = Vec.new()
  bag.push(Item.Potion(6))

  ryu.take_damage(21)
  for item in bag
    ryu.heal(heal_from(item))
  end
  bag.clear()
  print ryu.hp
  print bag.len()
end
```

The loop coordinates three abstractions. It iterates a collection, matches an
enum through `heal_from`, and asks a class to preserve the hit-point rule. It
does not need to know how any of those pieces are represented.

The output is 15 and then 0: the potion changes the fighter, and `clear` leaves
the bag ready to receive new items.

## What you learned

A class groups fields with methods. `init` establishes an instance's starting
state, `self` selects the receiving instance, and methods provide named paths
for changing or querying that state. Class values have identity and are passed
by reference, so mutations remain visible to other code holding the same
instance.

Gero also has structs for copied, method-free data and inheritance for related
class types. Those are useful once a program needs them; the complete rules
live in [`lang.md`](../lang.md#34-compound-types). Our fight needs neither yet.

---

**Next:** [Modules](08-modules.md) — moving these definitions into files with
clear responsibilities.
