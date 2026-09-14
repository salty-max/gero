# gero LSP

`gero lsp` is a language server for `.gas` and `.gr`, speaking the
Language Server Protocol over stdin/stdout. Editors spawn it; there is
nothing useful to run by hand.

The CLI surface — the subcommand and its flags — is specified in
[`cli.md` §3.14](cli.md). This document owns the protocol scope and
how to wire the server up from a client.

---

## 1. Scope

The server does two things: it reports what is wrong with a buffer,
and it rewrites a buffer into canonical form. Both answers come from
the same library entry points `gero check` and `gero fmt` use, so the
editor and the CLI cannot disagree about a file.

Everything else is out of scope, and deliberately so — see §6.

---

## 2. Transport

JSON-RPC 2.0 with `Content-Length` framing over stdio, per the base
protocol. Headers are ASCII, terminated by `\r\n\r\n`; the body is
UTF-8 JSON. `Content-Type` is accepted and ignored.

Everything on **stdout is a protocol message**. Anything the server
needs to say about itself goes to stderr.

A body larger than 16 MiB is refused rather than buffered — no
source file an editor can open comes near that, so a length that
large is a desynchronized stream.

---

## 3. Documents

| Suffix | Front-end |
|--------|-----------|
| `.gas` | assembler |
| `.gr` | Gero |
| anything else | ignored — the server publishes an empty diagnostic list and formats nothing |

Sync is **full text**: `textDocumentSync` is `1`, and every
`didChange` carries the whole buffer. Analysis re-reads the entire
document anyway, so incremental sync would be bookkeeping with no
payoff.

### Unsaved buffers

Analysis resolves the whole `use` (Gero) or `.include` (asm)
graph rooted at the document. Every file the editor holds open is read
from **its buffer** rather than from disk. Editing a library reddens
its importers on the next keystroke, with no save in between.

A document whose URI is not a `file://` URI — an unsaved "untitled"
buffer — has no import graph to resolve, and is analyzed standalone.

### Diagnostics follow the error, not the request

Checking one document reports on every file its graph implicates. Each
diagnostic is published against **its own** URI, positioned in that
file's coordinates — so an error in `lib.gr` lands on `lib.gr`, not at
the `use` line in whoever imported it.

The reverse direction matters just as much. An editor reports only the
buffer being typed in, but that edit can invalidate documents it said
nothing about. So the server records which files each document's
analysis read, and a change to any of them re-checks every open
document that read it. Editing a library therefore reddens its open
importers on the next keystroke. Documents that do not read the
changed file are left alone.

Three consequences worth expecting as a client author:

- `publishDiagnostics` arrives for files the editor never opened.
- `publishDiagnostics` arrives for open documents the editor did not
  report a change to.
- A file whose last error is fixed gets an explicit **empty** list.
  Without it the editor would keep showing diagnostics that no longer
  hold.

A document the editor has **closed** is no longer re-checked, even if
something it imported changes — the server keeps no text for it.

---

## 4. Capabilities

| Request | Behavior |
|---------|----------|
| `initialize` | Advertises `textDocumentSync: 1`, `documentFormattingProvider`, `definitionProvider`, `hoverProvider`, `referencesProvider` and `inlayHintProvider`. |
| `shutdown` | Answers `null`. |
| `exit` | Leaves with `0` after a `shutdown`, `1` without one. |
| `textDocument/didOpen` / `didChange` | Re-analyze, then publish. |
| `textDocument/didClose` | Drops the buffer. Its diagnostics stand until the file is reopened. |
| `textDocument/publishDiagnostics` | Notification, described below. |
| `textDocument/formatting` | One `TextEdit` spanning the document. |
| `textDocument/definition` | The declaration the name under the cursor binds to, or `null` (§6). |
| `textDocument/hover` | The name, its type where known, and what kind of declaration it is (§6). |
| `textDocument/references` | Every reference to the declaration under the cursor, in source order. `context.includeDeclaration` decides whether the declaration is among them. |
| `textDocument/inlayHint` | The inferred type of each `let` the source left unannotated (§6). |

Any other request is answered `-32601` (method not found) rather than
left hanging. Unknown *notifications* are dropped, since they carry no
id to answer against.

### Diagnostics

Exactly what `gero check` reports for the same tree, mapped to LSP:

| LSP field | Gero source |
|-----------|-------------|
| `range` | The diagnostic's span, resolved to zero-based line/character in its own file |
| `severity` | `error` / `warning` / `note` → `1` / `2` / `3` |
| `code` | The `E_` registry code (see [`lang-diagnostics.md`](lang-diagnostics.md)); omitted where the emission site carries none |
| `source` | Always `"gero"` |
| `message` | The human-readable summary |

Both front-ends run every phase before reporting: Gero parses,
type-checks, and codegen-validates; asm parses **and** resolves
opcodes. An unknown mnemonic or register parses cleanly and only fails
at resolution, so a server that stopped at the parse would show
nothing.

### Formatting

The response is a single `TextEdit` covering the whole document,
holding what `gero fmt` would write. The canonical printer rewrites
layout globally, so a minimal diff would rarely be smaller and could
be wrong.

A buffer that **does not parse** formats to no edits. Format-on-save
must never rewrite broken source from a partial tree. A buffer already
in canonical form likewise produces no edits.

---

## 5. Wiring a client

### Neovim (`nvim-lspconfig`)

`gero` is not in `lspconfig`'s registry, so define the server:

```lua
vim.filetype.add({ extension = { gr = "gero", gas = "geroasm" } })

vim.lsp.config["gero"] = {
  cmd = { "gero", "lsp" },
  filetypes = { "gero", "geroasm" },
  root_markers = { "gero.toml", ".git" },
}
vim.lsp.enable("gero")
```

Format on save:

```lua
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = { "*.gr", "*.gas" },
  callback = function() vim.lsp.buf.format({ async = false }) end,
})
```

### VS Code

The extension in `editors/vscode-gero` wires this up. To point a
generic client at the server yourself, spawn `gero lsp` with
`TransportKind.stdio` and register the `gero` / `gero-asm` language
ids.

### Helix

In `languages.toml`:

```toml
[language-server.gero]
command = "gero"
args = ["lsp"]

[[language]]
name = "gero"
scope = "source.gero"
file-types = ["gr"]
language-servers = ["gero"]
auto-format = true

[[language]]
name = "gero-asm"
scope = "source.gero-asm"
file-types = ["gas"]
language-servers = ["gero"]
auto-format = true
```

### Anything else

The server needs no initialization options, no workspace folders, and
no configuration. A client that can spawn a process and speak the base
protocol works: run `gero lsp`, send `initialize`, and open a file.

---

## 6. Resolved names

Go-to-definition and hover are provided for `.gr`, and answer from the
type-checker's own resolution rather than a second one.

`CheckedProgram.bindings` maps a reference's offset to the declaration
it binds to — kind, span, name, and the module for an imported one.
The server looks up the identifier under the cursor and reports what
the checker already decided. Nothing re-derives bindings from the AST,
which would be a second implementation agreeing with its author rather
than with the compiler.

A position on anything the checker did not bind — a keyword, a
comment, a name that does not resolve — answers `null` rather than
guessing.

The table is built even when a buffer does not compile, which is when
an editor is asked most.

Find-references is the same table read backwards: an entry names the
declaration its reference binds to, so the references to a declaration
are the entries pointing at it. Asking on a reference and asking on the
declaration give the same set, because both resolve to the same
declaration first.

Inlay hints come from `binder_types` rather than `bindings` — the type
of each named binding, keyed by its declaring identifier. Only a `let`
the source left unannotated gets one: repeating a type the author
wrote is noise, and the point is to show what was inferred.

### Not yet provided

Completion, semantic tokens and code actions. Each reads the same
tables and none needs anything further from the front ends; they are
unbuilt rather than blocked.

`.gas` is not wired for either feature yet. The assembler records
where each label and constant was declared (`asm.Symbol.decl_start`),
so the data is there and the server has not been taught to use it.

Syntax highlighting is out of scope for a different reason: it needs
no running server, and a grammar does it better. Both grammars exist —
[`tree-sitter-gero-asm`](https://github.com/salty-max/tree-sitter-gero-asm)
for `.gas` and
[`tree-sitter-gero-lang`](https://github.com/salty-max/tree-sitter-gero-lang)
for `.gr` — consumed by the Neovim / Helix / Zed setups in
[`tooling.md`](tooling.md).

So a buffer in an LSP-aware editor gets colour from the grammar and
diagnostics + formatting from this server, which is the division of
labour semantic tokens would otherwise have to reproduce from the
server side.
