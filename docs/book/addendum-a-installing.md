# Installing Gero

If you are reading this in the lab, you already have a compiler:
**Run** on a code block compiles it and prints underneath. This page
is for working on your own machine.

## The binary

```bash
brew install salty-max/tap/gero
```

That is macOS and Linux. Windows, or a version you want pinned, comes
from the GitHub releases — drop `gero` somewhere on your `PATH`.
Building from source wants Zig 0.16 or newer:

```bash
git clone https://github.com/salty-max/gero
cd gero
zig build
./zig-out/bin/gero --version
```

## The loop

One binary. The commands you will actually type:

```bash
gero compile hello.gr -o hello.gx   # Gero → bytecode
gero run hello.gx                   # execute it
gero fmt hello.gr                   # canonical formatting, no options
gero check hello.gr                 # errors without producing a file
gero disasm hello.gx                # bytecode → readable assembly
```

`compile` writes a cart. `run` loads that cart into a fresh machine
and executes from its entry point until `hlt`. `check` is the same
pipeline without writing a file — what an editor asks on every
keystroke. `fmt` has no options; there is one shape.

`disasm` is worth trying on the first cart you build. Nothing the
compiler did is hidden.

## Editors

The VS Code extension `gero` colours `.gr` and `.gas` and talks to
`gero lsp` for inline errors. Neovim and Helix consume tree-sitter
grammars for both suffixes. Wiring them is a few lines in your
editor config; the grammars live next to the CLI in the same GitHub
org.
