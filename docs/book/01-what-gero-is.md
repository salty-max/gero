# 1. What Gero is

The quickest way to understand a programming language is to make it do
something. We will begin with a complete program, run it, and then take it
apart.

## Run something first

Create a file named `hello.gr` and put this in it:

```gero
def main()
  print "Hello, gero!"
end
```

There are three parts to this program.

`def main()` declares a **function** named `main`. A function is a named group
of instructions. `main` has a special job: it is where the program begins.
The empty parentheses mean that it needs no information from whoever starts
it.

`print "Hello, gero!"` is the instruction inside the function. `print` sends a
value to the program's output. The quotation marks make `"Hello, gero!"` a
piece of text rather than a name or an instruction.

`end` marks the end of the function. Indentation makes the shape easier for a
person to see; `end` tells the compiler where the shape finishes.

Compile the source file:

```bash
gero compile hello.gr -o hello.gx
```

Then run the file that command created:

```bash
gero run hello.gx
```

The program prints:

```text
Hello, gero!
```

That is the basic loop: write source, compile it, run the result.

Before reading further, change the message and run the two commands again.
The change is small, but it establishes something important: the source file
is yours, and the output follows from what you wrote.

## Source and carts

The two files have different jobs.

`hello.gr` is **source code**. It is written for people as well as for the
compiler. Names, line breaks, and comments help explain the program.

`hello.gx` is a **cart**. It contains bytecode: compact instructions for the
Gero virtual machine. Your laptop cannot execute those instructions directly,
so `gero run` creates the virtual machine in software and asks it to execute
the cart.

The compiler is the translator between the two:

```text
hello.gr  -- gero compile -->  hello.gx  -- gero run -->  output
```

When compilation fails, no useful cart is produced. That is helpful. The
compiler can point to a problem while the program is still text you can edit,
rather than letting the machine guess what you meant.

## The machine in one page

The virtual machine is a deliberately small computer. It has sixteen
registers, each wide enough to hold a 16-bit number, and 64 KB of directly
addressable memory. It executes one instruction after another until the
program reaches `hlt`.

You do not need to understand registers or `hlt` to write Gero. For now, the
useful fact is that the machine has firm limits. Memory is a finite place where
the program and its data must fit. Instructions are work that takes time.
Later chapters will make both costs visible when a programming decision
depends on them.

There is no operating system inside the VM, no process tree, and no dynamic
linker. A host such as `gero run` can provide output and persistence, but the
cart itself sees the same machine wherever it runs.

The constraint is the point.

Modern computers hide many physical details because most programs should not
have to care about them. Gero lets you work at a higher level too, but on a
machine small enough that you can still understand the cost of your choices.
The goal is not to claim that older computers were better. It is to make their
kind of reasoning available in a controlled place.

## Two ways to program it

The machine has two languages. Both produce `.gx` carts.

**Gero** is the language this book teaches. It gives you types, functions,
classes, modules, and collections. You describe the rules of the program, and
the compiler chooses the machine instructions.

**Assembly** exposes those instructions directly. It is useful when the exact
bytes or cycle count matter, and it is the language taught in The Gero
Machine.

Neither language produces a more real cart. They are two ways of writing for
the same machine. [Gero and assembly](addendum-b-assembly.md) compares the two
when you are ready; nothing there is needed for the next chapter.

## The tools you need now

The first chapters use four commands:

```bash
gero compile hello.gr -o hello.gx  # create a cart
gero run hello.gx                  # run the cart
gero check hello.gr                # check without creating a cart
gero fmt hello.gr                  # format the source consistently
```

`gero check` is useful while writing because it reports errors without doing
the final build. `gero fmt` rewrites whitespace into the standard style, so
you do not have to invent formatting rules.

One more command will become useful later:

```bash
gero disasm hello.gx
```

It translates bytecode back into readable assembly. The output will not mean
much yet. The important promise is that the compiler's work can be inspected.

## What you learned

A Gero program begins in `main`. The `.gr` file is source for people and the
compiler; `gero compile` turns it into a `.gx` cart; `gero run` executes that
cart on the virtual machine. You have already completed the whole development
loop once.

If Gero is not installed yet, [Installing Gero](addendum-a-installing.md)
covers the binary and editor setup.

---

**Next:** [Values and types](02-values-and-types.md) — giving names to the
information a program remembers.
