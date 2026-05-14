# Gero — Tooling Guide

End-to-end setup for a gero asm project: install the CLI, wire up
your editor, and drop the right CI + pre-commit recipes into your
own repo. Companion to [`cli.md`](./cli.md) (the subcommand
reference) and [`asm.md`](./asm.md) (the language spec).

> **Philosophy**: `gero new` scaffolds a deliberately minimal
> project — no `.github/`, no `lefthook.yml`, no opinionated
> editor configs. This guide is the menu of opt-in recipes for
> the stacks you want to use. Guide, don't force.

---

## Contents

1. [Install gero](#1-install-gero)
2. [Editor setup](#2-editor-setup)
3. [Day-to-day workflows](#3-day-to-day-workflows)
4. [CI integration](#4-ci-integration)
5. [Pre-commit hooks](#5-pre-commit-hooks)

---

## 1. Install gero

### Homebrew (macOS / Linux)

```bash
brew install salty-max/tap/gero
```

The formula pulls the latest tagged release. Pin to a specific
version with:

```bash
brew install salty-max/tap/gero@0.2.0
```

### Pre-built binaries from GitHub Releases

Each tagged release ships archives for macOS / Linux / Windows
under [Releases](https://github.com/salty-max/gero/releases).
Extract anywhere on your `$PATH`:

```bash
# Replace <version> + <platform> with the values from the release page.
curl -L https://github.com/salty-max/gero/releases/download/<version>/gero-<platform>.tar.gz | tar xz
sudo mv gero/bin/gero /usr/local/bin/gero
```

### From source

Requires [Zig 0.16+](https://ziglang.org/download/):

```bash
git clone https://github.com/salty-max/gero
cd gero
zig build install
./zig-out/bin/gero --version
```

### Verify

```bash
gero --version       # → gero 0.2.0
gero --help          # full subcommand list
```

---

## 2. Editor setup

Three editor families covered today: VS Code, Neovim / Helix /
Zed (tree-sitter consumers), and "anything else" (TextMate /
syntax-only).

### 2.1 VS Code

The extension ships a TextMate grammar + language config (file
association, comment toggle, bracket pairs).

**Until the marketplace publish lands**: install from a
local `.vsix`.

```bash
git clone https://github.com/salty-max/vscode-gero
cd vscode-gero
npx vsce package           # produces gero-asm-<version>.vsix
code --install-extension gero-asm-*.vsix
```

Or symlink the repo directly into VS Code's extensions dir for
live development:

```bash
ln -s "$(pwd)" ~/.vscode/extensions/salty-max.gero-asm-dev
```

Then reload VS Code (`Cmd+Shift+P` → "Reload Window") and open
any `.gas` file — you should see syntax coloring out of the box.

**Marketplace install** (once the extension is published):

```bash
code --install-extension salty-max.gero-asm
```

### 2.2 Neovim (tree-sitter)

The grammar repo
[`tree-sitter-gero-asm`](https://github.com/salty-max/tree-sitter-gero-asm)
ships with `highlights.scm` + `folds.scm` + `indents.scm`.

**Until the nvim-treesitter registry PR merges**, install
manually via your plugin manager. Example with
[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
-- ~/.config/nvim/lua/plugins/gero-asm.lua
return {
  {
    "salty-max/tree-sitter-gero-asm",
    build = function()
      -- Compile the parser .so into Neovim's runtime parser dir.
      local clone_dir = vim.fn.stdpath("data") .. "/lazy/tree-sitter-gero-asm"
      local out_dir = vim.fn.stdpath("data") .. "/site/parser"
      vim.fn.mkdir(out_dir, "p")
      vim.fn.system({
        "cc",
        "-o",
        out_dir .. "/gero_asm.so",
        "-shared",
        "-Os",
        "-fPIC",
        "-I",
        clone_dir .. "/src",
        clone_dir .. "/src/parser.c",
      })
      -- Mirror the queries dir into your config so nvim-treesitter
      -- finds them.
      local queries = vim.fn.stdpath("config") .. "/queries/gero_asm"
      vim.fn.mkdir(queries, "p")
      for _, q in ipairs({ "highlights", "folds", "indents" }) do
        vim.fn.system({
          "ln",
          "-sf",
          clone_dir .. "/queries/" .. q .. ".scm",
          queries .. "/" .. q .. ".scm",
        })
      end
    end,
    init = function()
      vim.filetype.add({ extension = { gas = "gero_asm" } })
    end,
  },
}
```

Then in any `.gas` buffer:

```vim
:edit src/main.gas
:set ft?           " should print "filetype=gero_asm"
:Inspect           " (Neovim 0.10+) shows the tree-sitter scope under the cursor
```

**Once shipped to the registry**, the whole snippet
collapses to:

```lua
require("nvim-treesitter.configs").setup({
  ensure_installed = { "gero_asm" },
})
```

### 2.3 Helix

Add to `~/.config/helix/languages.toml`:

```toml
[[language]]
name = "gero-asm"
scope = "source.gero_asm"
file-types = ["gas"]
comment-token = ";"
indent = { tab-width = 2, unit = "  " }

[[grammar]]
name = "gero-asm"
source = { git = "https://github.com/salty-max/tree-sitter-gero-asm", rev = "<tag>" }   # pin to a tagged release
```

Then build the grammar + queries:

```bash
hx --grammar fetch
hx --grammar build
mkdir -p ~/.config/helix/runtime/queries/gero-asm
ln -sf /path/to/tree-sitter-gero-asm/queries/highlights.scm ~/.config/helix/runtime/queries/gero-asm/highlights.scm
```

### 2.4 Anything else (Sublime / TextMate)

The VS Code extension's grammar file
(`grammars/gero-asm.tmLanguage.json`) is a vanilla TextMate
grammar — drop it into Sublime Text's
`Packages/User/` or any TextMate-derived editor's bundle
directory.

### 2.5 LSP (not yet shipped)

`gero lsp` will offer in-editor diagnostics (from `gero check`)
+ format-on-save (from `gero fmt`) for both `.gas` and `.gr`
files. Waits on the gero-lang front-end so the LSP serves both
languages in one ship. Track at
[#157](https://github.com/salty-max/gero/issues/157).

---

## 3. Day-to-day workflows

Once you have the CLI + editor set up, the development loop is:

```bash
gero new my-cart            # scaffold a fresh project
cd my-cart
gero build                  # → out/debug/my-cart.gx
gero run out/debug/my-cart.gx
```

Other subcommands you'll use:

| Command | What it does |
|---|---|
| `gero check` | Parse + codegen-validate every project source (no `.gx` written). Editor-LSP-style smoke. |
| `gero fmt` | Canonical-format `.gas` files in place. Reads `[fmt]` from `gero.toml` for overrides. |
| `gero fmt --check` | CI variant — exit 8 if anything would be reformatted. |
| `gero test` | Walk `[test].include` for `.gas` programs paired with `.expected`, assemble + run, diff stdout. |
| `gero info <file.gx>` | Print the `.gx` file header (entry point, banks, debug symbols). |
| `gero disasm <file.gx>` | Disassemble bytecode back to canonical asm. |

Run inside a project (cwd or any ancestor has `gero.toml`),
`gero check` / `gero fmt` / `gero test` resolve their file lists
from the manifest automatically. Pass explicit paths to override.

See [`cli.md`](./cli.md) for the full reference.

---

## 4. CI integration

Two recipes — pick the matching provider (or adapt to whatever
runner you have).

### 4.1 GitHub Actions

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  gero:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install gero
        run: |
          brew tap salty-max/tap
          brew install gero

      - name: Check
        run: gero check

      - name: Format check
        run: gero fmt --check

      - name: Test
        run: gero test
```

**Linux runner**: swap `runs-on: macos-latest` for
`ubuntu-latest`. The Homebrew tap supports both (and Homebrew on
Linux works with the same incantation).

**Pin to a specific gero version**: replace `brew install gero`
with `brew install salty-max/tap/gero@0.2.0` (semver-tagged
formulas land per release).

### 4.2 GitLab CI

```yaml
# .gitlab-ci.yml
image: homebrew/brew:latest

stages: [check]

variables:
  GERO_VERSION: "0.2.0"

before_script:
  - brew tap salty-max/tap
  - brew install gero@${GERO_VERSION}

check:
  stage: check
  script:
    - gero check
    - gero fmt --check
    - gero test
```

---

## 5. Pre-commit hooks

Three flavors covering the common hook managers + the bare-metal
case.

### 5.1 lefthook

```yaml
# lefthook.yml — drop in your repo root
pre-commit:
  parallel: true
  commands:
    gero-check:
      glob: "*.gas"
      run: gero check {staged_files}
    gero-fmt:
      glob: "*.gas"
      run: gero fmt --check {staged_files}
```

Install once (per machine):

```bash
brew install lefthook
lefthook install
```

`{staged_files}` runs each command only on the files git is about
to commit — fast.

### 5.2 pre-commit framework

```yaml
# .pre-commit-config.yaml
repos:
  - repo: local
    hooks:
      - id: gero-check
        name: gero check
        entry: gero check
        language: system
        files: \.gas$
      - id: gero-fmt
        name: gero fmt --check
        entry: gero fmt --check
        language: system
        files: \.gas$
```

Install:

```bash
pip install pre-commit
pre-commit install
```

### 5.3 Plain `.git/hooks/pre-commit`

Zero deps. Drop this in `.git/hooks/pre-commit` and `chmod +x`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Only check the .gas files staged in this commit.
staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.gas$' || true)
[[ -z "$staged" ]] && exit 0

# Run check + fmt --check across the staged set.
echo "$staged" | xargs gero check
echo "$staged" | xargs gero fmt --check
```

Commit the file under `scripts/git-hooks/pre-commit` and have
teammates `ln -sf $(pwd)/scripts/git-hooks/pre-commit .git/hooks/pre-commit`
so the hook is versioned with the project.

---

## Troubleshooting

**`gero check` fails with "no gero.toml"**: you're outside a
project. Either `cd` into one, or pass explicit paths
(`gero check src/foo.gas`).

**Neovim doesn't highlight `.gas` files**: confirm
`:set ft?` reports `filetype=gero_asm`. If not, the
`vim.filetype.add` block didn't run — check your plugin manager
loaded the spec. Then `:Inspect` over a known token to confirm
tree-sitter is active.

**`gero fmt --check` flags freshly-scaffolded files**: shouldn't
happen (templates are canonical-form). If you hit this,
file a bug.

**VS Code shows `.gas` as plain text**: verify the extension
shows up under `code --list-extensions`. The grammar might have
been disabled per-workspace — check the file's language mode in
the bottom-right status bar.

**Pre-commit hook is too slow**: lefthook with `parallel: true`
runs check + fmt concurrently. For huge changesets, pass
`--quiet` to suppress the per-file `✓` lines.
