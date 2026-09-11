# gero-lab — Browser Playground Spec

The web playground for the Gero toolchain: write `.gas` or `.gr` in
the browser, assemble or compile it, and run it on the Gero VM with a
full debugger cockpit — registers, memory, stack, disassembly,
breakpoints, single-step.

> **Layer separation:** gero-lab is a web application. It depends on
> the `gero` library, compiled to WebAssembly, for every toolchain
> operation — it reimplements nothing. This file lives in `gero/docs/`
> because the engine boundary is a contract between the two, and gero
> authors need it at hand when changing the public surface.

gero-lab is a **toolchain cockpit**, not a game runtime. The
peripherals — display, audio, input — belong to
[gtx-16](./gtx-16.md), which is a separate consumer of the same VM.

---

## 1. Layers

Three layers, two boundaries. Each boundary is a contract that can be
versioned and tested independently.

```
┌─────────────────────────────────────────────┐
│  UI (main thread)                           │
│  editor · panes · transport controls        │
└───────────────┬─────────────────────────────┘
                │  worker protocol (§3)
┌───────────────┴─────────────────────────────┐
│  Engine worker                              │
│  session state · run loop · event batching  │
└───────────────┬─────────────────────────────┘
                │  wasm exports (§2)
┌───────────────┴─────────────────────────────┐
│  gero.wasm                                  │
│  asm · lang · vm · disasm                   │
└─────────────────────────────────────────────┘
```

The UI never touches the wasm module directly. The worker owns the VM
instance and every allocation inside the module; the UI owns nothing
but plain serializable messages. This keeps the run loop off the main
thread, so a tight `while` loop in a user program cannot freeze the
page.

The lower boundary is also where the repositories divide: `gero.wasm`
is built and gated in the gero repository, the two layers above it live
with the application. §10 says why.

---

## 2. The wasm surface

`gero` builds to `wasm32-freestanding` with an explicit C-ABI export
set. Freestanding rather than `wasm32-wasi`: the lab needs a narrow,
purpose-built surface, not a POSIX shim. Print syscalls already route
through `vm.host.out`, so the binding captures them into a ring buffer
instead of needing stdout. The `wasm32-wasi` target stays as-is for
CLI use.

### 2.1 Memory ownership

The module owns a bump arena reset per operation. Every export that
returns variable-length data writes into a module-owned buffer and
returns `(ptr, len)`; the caller copies out before the next call. No
JS-side frees, no leaks across the boundary.

**A pointer is an offset from the arena's base**, not an absolute
address. A host resolves one as:

```js
memory.buffer + gero_arena_base() + ptr
```

The indirection buys uniformity: an offset means the same thing on
wasm32, where a pointer already *is* a linear-memory offset, and on the
64-bit host the module's tests run on.

`0` is never a valid pointer — the arena reserves its first word — so
an export signals failure by returning a null pointer without that
colliding with a legitimate first allocation.

**Two lifetimes in one region.** Scratch grows up from the base and is
reset at the start of every operation; **input grows down from the
top** and is not. An export's arguments are written *before* the call
and must still be there when it reads them — resetting one region on
entry would free the other's contents. The cursors meet in the middle,
and exhaustion is when they cross.

A host reclaims input with `gero_reset`, once it is done with a result.

**Lifecycle**

| Export | Purpose |
|---|---|
| `gero_init(arena_bytes) -> Status` | Size the arena. `0` takes the default; a larger request is clamped. Calling it again resets the session. |
| `gero_alloc(len) -> ptr` | Reserve `len` bytes to write source into. Survives an operation. `0` means the region cannot satisfy it. |
| `gero_reset()` | Drop the last operation's scratch **and** the inputs written for it. |
| `gero_arena_base() -> ptr` | Where the arena begins in linear memory. |
| `gero_arena_used()` / `gero_arena_limit()` | For a host sizing its ceiling. |
| `gero_result_size() -> u32` | So a decoder can assert it agrees with the module. |
| `gero_version() -> Result` | The gero version this module was built from, for the `ready` event (§3.2). |

**The virtual file set**

| Export | Purpose |
|---|---|
| `gero_file_put(name, contents) -> Status` | Add a buffer, or replace one of the same name. |
| `gero_file_remove(name) -> Status` | Drop a buffer. Removing an absent one is not an error. |
| `gero_files_clear()` | Empty the set. |
| `gero_file_count() -> u32` | How many buffers it holds. |

The set has storage of its own, separate from the arena: buffers
outlive an operation, and compiling must not be able to evict the
sources it is compiling.

Exhaustion is **reported, not trapped**: `gero_alloc` returns `0` and
an export returns `out_of_memory`. A host raises its ceiling and
retries rather than meeting an instance that has to be discarded.

### 2.2 Exports

**Toolchain**

| Export | Purpose |
|---|---|
| `gero_assemble(src_ptr, src_len) -> Result` | `.gas` → `.gx` |
| `gero_compile(name_ptr, name_len) -> Result` | `.gr` → `.gx`, resolving `use` imports from the virtual file set (§4.2) |
| `gero_check(name_ptr, name_len, lang) -> Result` | Diagnostics only, no image — the editor's fast path |
| `gero_format(src_ptr, src_len, lang) -> Result` | Canonical formatting of one buffer, matching `gero fmt` |
| `gero_disasm(gx_ptr, gx_len, bank, show_bytes) -> Result` | `.gx` → annotated assembly; `bank` of `0xFFFFFFFF` selects the base image, and a non-zero `show_bytes` adds the hex column beside each instruction |
| `gero_debug_info(gx_ptr, gx_len) -> Result` | The symbol and line tables (§6) as JSON |

A `Result` carries a status, an optional payload (`.gx` bytes or
formatted text), and a diagnostics array. Both source languages use one
shape, keyed by a `lang` discriminant, so the UI has one code path.

Every export returns a pointer to a single `Result` in module memory,
valid until the next call. Its layout is fixed: **five little-endian
`u32` fields**, twenty bytes, decoded with five reads at known offsets
and no schema.

| Offset | Field | Meaning |
|---|---|---|
| `0` | `status` | See below |
| `4` | `payload_ptr` | `.gx` bytes or UTF-8 text, `0` when there is none |
| `8` | `payload_len` | |
| `12` | `diagnostics_ptr` | UTF-8 JSON array, `0` when there is none |
| `16` | `diagnostics_len` | |

| `status` | Meaning |
|---|---|
| `0` `ok` | Produced its payload with no fatal diagnostic |
| `1` `diagnostics` | Ran and reported diagnostics; payload absent or partial |
| `2` `not_initialized` | `gero_init` has not been called |
| `3` `out_of_memory` | The arena cannot satisfy the request |
| `4` `bad_lang` | A `lang` discriminant naming no front-end |
| `5` `bad_argument` | A `(ptr, len)` outside the arena |

The status distinguishes *nothing was reported* from *something was*.
A host branches on it rather than on whether the payload happens to be
empty — an empty JSON array is still two bytes.

The payload stays **raw bytes**; only the diagnostics are JSON, because
that is the one part with a shape worth sharing. Those objects come
from the same writer `gero check --format=json` uses, so an error's
wording, code, and span are identical in a terminal and in a browser
(§5).

`lang` is `0` for `.gas` and `1` for `.gr`.

**VM**

| Export | Purpose |
|---|---|
| `gero_vm_create()` / `gero_vm_destroy(h)` | Session lifecycle |
| `gero_vm_load(h, gx_ptr, gx_len)` | Parse the archive and boot |
| `gero_vm_reset(h)` | Re-boot the loaded image |
| `gero_vm_step(h, n) -> StepOutcome` | Execute up to `n` instructions. The payload is four little-endian `u32`s: reason, `ip`, fault vector, and instructions retired. Reasons are `0` budget, `1` halted, `2` breakpoint, `3` faulted, `4` not-loaded — the run loop branches on all five, so they are not collapsed. |
| `gero_vm_regs(h) -> ptr` | Register file snapshot |
| `gero_vm_peek(h, addr, len) -> ptr` | Read memory through the mapper |
| `gero_vm_poke(h, addr, ptr, len)` | Write memory through the mapper |
| `gero_vm_set_reg(h, reg, value)` | Poke a register |
| `gero_vm_raise_irq(h, vector)` | Inject a maskable interrupt |
| `gero_vm_take_output(h) -> Result` | Drain the print buffer. `diagnostics_len` carries bytes **dropped** because the program outran it, so a flood is visible rather than silent. A full buffer never fails the program: the VM raises invalid-opcode when its writer errors, and a chatty program must not become a crashing one. |
| `gero_vm_sram(h) -> ptr` / `gero_vm_load_sram(h, ptr, len)` | Persistence (§7) |

A `.gx` that will not load reports **why** in the same words `gero run`
uses, not a bare status.

Multiple sessions coexist — `gero_vm_create` returns a handle, and
neither the VM nor the toolchain holds module-level mutable state, so
sessions are independent.

`StepOutcome` maps `vm.StepResult` — `cont`, `branched`, `halted`,
`halted_on_fault`, `breakpoint` — plus the instruction count actually
retired, which is under `n` when the run stopped early.

### 2.3 Breakpoints

Breakpoints use the ISA's `brk` opcode rather than a worker-side
address set. Setting one patches the byte at the address and stores the
original; clearing restores it. `vm.step` already returns
`.breakpoint` for `brk`, so the run loop needs no per-instruction
address comparison — **the cost of a breakpoint is zero when it isn't
hit**, which is what lets the fastest speed setting actually be fast.

| Export | Purpose |
|---|---|
| `gero_vm_breakpoint_add(h, addr)` | Patch `brk` over the byte at `addr`. Setting one twice is not an error. |
| `gero_vm_breakpoint_remove(h, addr)` | Restore the displaced byte. Clearing an unset one is not an error. |
| `gero_vm_breakpoint_clear(h)` | Drop them all. |
| `gero_vm_breakpoint_count(h)` | For the `bp` event (§3.2). |

**Patched bytes are invisible to the UI.** `gero_vm_peek` returns the
displaced byte, so the memory pane and any disassembly built from it
show the user's program rather than the instrumentation. Without that,
setting a breakpoint would visibly rewrite the program on screen.

**Stopping reports the address that was set.** `step` advances past
`brk` like any one-byte instruction, so `ip` would otherwise be one
byte past what the user clicked. It is rewound.

**Resuming steps over the patch.** The `brk` still occupies the place
of the program's own instruction, so it is lifted for exactly one step
and then replaced. Without that, resuming would trap on the same
breakpoint forever.

**Breakpoints belong to the image they were set in**, and `load` and
`reset` clear them. An address means nothing once a different program
occupies it.

**A breakpoint mid-instruction is the caller's responsibility.** The
module cannot detect one: knowing where an instruction begins requires
decoding forward from a known boundary, and a host may set a
breakpoint anywhere. Patching the middle of an instruction corrupts
it — execution reaching that address runs `brk` as an operand, or the
instruction decodes to something else entirely.

A host avoids this by setting breakpoints only at addresses it knows to
be instruction starts. The line table (§6) provides exactly those: a
UI that sets breakpoints from source lines is safe by construction,
which is the intended path.

---

## 3. Worker protocol

A versioned message protocol over comlink. `PROTOCOL_VERSION` is a
single integer; the UI refuses to connect to a worker whose version it
doesn't recognize, which turns a stale service-worker cache into a
clear error instead of silent misbehavior.

### 3.1 Commands

| Command | Payload |
|---|---|
| `init` | memory size, entry override |
| `build` | source set + entry file + language |
| `load` | `.gx` bytes (skips the toolchain — for a shared image) |
| `reset` | — |
| `run` | starting `ip` |
| `pause` | — |
| `step` | instruction count |
| `breakpoints` | add / remove address lists |
| `peek` | address, length, request id |
| `poke` | address, bytes |
| `setReg` | register, value |
| `irq` | vector |

### 3.2 Events

| Event | Payload |
|---|---|
| `ready` | protocol version, gero version |
| `built` | `.gx` size, entry, debug info (§6), diagnostics |
| `paused` | reason (`breakpoint` / `manual` / `fault` / `halt`), `ip`, fault detail |
| `snapshot` | register file |
| `mem` | address, bytes, request id |
| `output` | text drained from the print buffer |
| `trace` | `ip`, before / after snapshots |
| `irq` | phase (`enter` / `exit`), `ip` |
| `bp` | added / removed / total |

### 3.3 Run loop and back-pressure

`run` executes in slices — a fixed instruction budget per turn — and
yields between them so `pause` is honored promptly. Events coalesce
per slice: one `snapshot`, one `output`, one `mem` per outstanding
request. A program printing in a tight loop produces a bounded event
rate regardless of how fast it runs.

The UI's speed control sets the slice budget. At the lowest setting
one instruction per turn drives the step-through visualization; at the
highest the loop runs uninterrupted until a breakpoint, fault, or
`hlt`.

---

## 4. Source languages

Both `.gas` and `.gr` are first-class. Neither is a later addition:
the language discriminant is present in every toolchain export, every
`build` command, and the editor configuration.

### 4.1 Per-language behavior

| | `.gas` | `.gr` |
|---|---|---|
| Toolchain entry | `gero_assemble` | `gero_compile` |
| Comment syntax | `;` | `--` |
| Multi-file | `include` (textual splice) | `use` (module import) |
| Formatter | `gero_format(…, gas)` | `gero_format(…, gr)` |

### 4.2 The virtual file set

A session holds a named set of source buffers, not a single string.
`include` and `use` resolve against that set, so a multi-file program
works in the browser exactly as it does on disk. The entry file is
explicit; unreferenced buffers are still checked, matching
`gero check`'s behavior of validating every file rather than only the
reachable ones.

Resolution is closed: a path that escapes the set is a diagnostic, not
a network fetch. The lab never loads code from a URL at build time.

### 4.3 Highlighting

The editor colours source with the **same tree-sitter grammars the
native editors use**, loaded in the browser through
[`web-tree-sitter`](https://github.com/tree-sitter/tree-sitter/tree/master/lib/binding_web):

| Language | Grammar | Artifact |
|---|---|---|
| `.gas` | [`tree-sitter-gero-asm`](https://github.com/salty-max/tree-sitter-gero-asm) | `tree-sitter-gero_asm.wasm` |
| `.gr` | [`tree-sitter-gero-lang`](https://github.com/salty-max/tree-sitter-gero-lang) | `tree-sitter-gero_lang.wasm` |

Each grammar builds that artifact in CI on tag and attaches it to the
release, so the lab fetches a versioned file rather than compiling a
grammar it cannot compile:

```
https://github.com/salty-max/tree-sitter-<name>/releases/download/<tag>/tree-sitter-<name>.wasm
```

The `queries/highlights.scm` shipped alongside each grammar is the
lab's theme mapping too. Editors and the lab therefore colour the same
token the same way by construction, not by two teams agreeing.

**Why not a CodeMirror or Monaco mode.** A hand-written mode is a
second grammar, and it drifts — the failure §11 records for the VM,
in a smaller place. The lab holds no token table for the same reason it
holds no opcode table.

**Why not semantic tokens.** They would come from the wasm module and
so could not drift, but they need the symbol table `docs/lsp.md` §6
gates hover and go-to-definition on. Highlighting does not need to wait
for that, and a grammar answers it better regardless: it colours a
buffer that does not compile, which is most buffers most of the time.

**A language with no grammar renders as plain text.** That is the only
fallback. It is not a licence to write a mode for the gap — the gap is
closed by publishing a grammar, and both languages have one.

**Build order.** The lab's highlighting depends on a tagged grammar
release carrying its `.wasm`. Both do from `tree-sitter-gero-asm`
v0.3.1 and `tree-sitter-gero-lang` v0.1.1 onward; earlier tags carry
the grammar but no browser artifact.

---

## 5. Diagnostics

One contract across the CLI, the editor, and the lab. The wasm
diagnostics array is the same shape `gero check --format=json` emits —
code, severity, message, file, span, and any secondary spans and
notes.

This is a deliberate single source of truth: an error's wording and
code are identical whether a user hits it in a terminal, in an
editor's problem list, or in the lab's gutter. A change to a
diagnostic surfaces in all three, and `docs/lang-diagnostics.md`
remains the one registry.

Rendering is the lab's own: spans become inline squiggles and gutter
markers rather than the CLI's caret art.

---

## 6. Debug information

The cockpit maps machine state back to source. Two tables, both
carried in the `.gx` debug section and returned by `built`:

- **Symbols** — address → name, for labels, functions, and globals.
  Drives the disassembly's label column and the memory pane's
  annotations.
- **Lines** — address range → (file, line, column). Drives
  source-level stepping, the current-line highlight, and setting a
  breakpoint by clicking a source line rather than typing an address.

Both tables live in the `.gx` debug section, emitted only when the
image is built with debug symbols, so release images carry neither.

Without debug information the lab still functions — the disassembly,
memory, and register panes need none of it. Source-level features
degrade to address-level ones.

---

## 7. Persistence

Three kinds of state, three lifetimes:

- **Source buffers** — the working set, saved to browser storage on
  edit and restored on load. Losing a tab must not lose work.
- **SRAM** — a program's `.sav` banks, exposed through
  `gero_vm_sram`. Stored per program identity so a cart's saved game
  survives a reload, matching what the CLI writes to a `.sav` file.
- **Session state** — breakpoints, pane layout, speed, theme. Local
  to the browser; never part of a shared link.

## 8. Sharing

A program shares as a URL carrying the compressed source set and entry
point — not a `.gx`. Sharing source means the link stays readable, and
the recipient assembles with their own toolchain version rather than
running an opaque blob from a stranger.

Links are self-contained: no server, no stored state, no account. A
shared link that exceeds a practical URL length is refused with a
message suggesting file download instead of silently truncating.

---

## 9. Samples

The lab ships a sample set covering both languages, drawn from the
repository's own example corpus so samples cannot drift from what CI
proves works: the `.gas` programs under `examples/asm/` and the `.gr`
programs under `examples/lang/`.

A sample that fails to build is a build failure, not a runtime
surprise — the sample set is gated the same way the example corpus is.

---

## 10. Build and gating

The split follows the toolchain boundary, not the product boundary.

**In the gero repository**: the wasm module and the gate that proves it
runs. Both are Zig artifacts — a `zig build` target and a Zig test —
and both need the working tree rather than a published release. A
change to the ISA, the assembler, or the language compiler rebuilds and
re-gates the module in the same commit, so **the module can never lag
the toolchain it exposes**.

**In its own repository**: the web application — worker, UI,
persistence, sharing. It brings its own toolchain (bun / vite / React),
its own lint and test conventions, and its own CI. Holding a frontend
to rules written for a VM serves neither.

- The wasm module is a `zig build` artifact like any other target.
- A smoke test builds each sample through the wasm module and runs it
  to `hlt`, comparing output against the same `.expected` files the
  CLI example gate uses. This is what turns "wasm32 compiles" into
  "wasm32 runs" — a runtime check on a target that otherwise only
  gets a compile check. It lives here because it needs the module and
  the example corpus in one CI run; split them and the fixtures
  duplicate and drift.
- The Zig gates (`zig build verify` / `ci`) stay authoritative for
  `src/`, `apps/`, and `tools/`, and now cover the module and its
  smoke gate. The application's lane covers the application.
- `build.zig.zon`'s `paths` allowlist excludes the wasm entry point, so
  nothing lab-shaped reaches consumers who fetch gero as a library.

### Why the application may lag and the module may not

A module that lags is a playground demonstrating semantics the VM no
longer has — the `ret`-encoding drift of §11, shipped as a feature.
That is the failure this document exists to prevent, and keeping the
module in-tree prevents it outright.

A UI that lags shows an older pane layout. The two are not the same
risk, and paying for the second with a mixed-toolchain repository is a
bad trade.

What makes the lag safe rather than silent is that both boundaries are
versioned: `PROTOCOL_VERSION` (§3) and the `Result` encoding (§2.2).
An application built against an older module refuses to connect and
says so. It does not quietly misbehave.

### Samples across the boundary

§9 draws the sample set from `examples/`, which lives here. The wasm
module's release therefore carries the sample sources alongside it —
they are already gated by the smoke test above, so they ship as part of
the artifact that proves they work. The application consumes them; it
does not vendor its own copies.

A release publishes both as loose assets, since a browser host fetches
them by URL and cannot unpack an archive:

| Asset | Contents |
|---|---|
| `gero.wasm` | The module, built `ReleaseSmall` for `wasm32-freestanding` |
| `samples.json` | The manifest: `{ version, samples: [{ name, lang, entry, files }] }`, where `files` maps a name to its source. A multi-file sample is one entry with several `files` — `examples/asm/banks` is one program in three. |
| `book.json` | The Gero Book, packed from `docs/book/`: `{ version, title, chapters: [{ slug, title, file, body }] }`. Front matter uses an empty `slug`. The application renders it; it does not vendor the chapters. |

The book is teaching source that must stay in lockstep with the
compiler — every fenced block is already gated here — so it ships
beside the module for the same reason the samples do. A ` ```gero `
block that declares `main` can be opened in the playground; CLI
walkthroughs (`gero compile`, `brew install`) stay in the markdown
until the chapters grow a lab-shaped telling.

---

## 11. What gero-lab explicitly does NOT do

These absences are deliberate.

- **No peripherals.** No display, audio, or input. That is gtx-16's
  layer; a lab that grew a framebuffer would become a second, worse
  console.
- **No server.** No accounts, no stored programs, no build queue.
  Everything runs in the browser; sharing is a URL.
- **No second implementation.** Every toolchain and VM operation goes
  through the wasm module. The lab holds no opcode table, no
  instruction semantics, no assembler. A prior TypeScript
  implementation demonstrated the failure mode: it drifted to a
  different `ret` encoding than the ISA and silently stopped being
  able to run current programs.
- **No editing of `.gx` bytes.** The lab is a source-level tool.
  Memory poking during a session is a debugger affordance, not an
  image editor.
- **No network fetches at build time.** Imports resolve within the
  session's file set.

---

## 12. Why this shape

**Why a worker rather than the main thread?** A user program is
arbitrary code, including an infinite loop. On the main thread that
hangs the page and loses the user's source. In a worker it is a
`pause` away from recovery.

**Why `brk` rather than an address set?** Address comparison costs
something on every instruction, forever, to support a feature used
rarely. Patching costs something once per breakpoint toggle. The ISA
already defines the opcode and the VM already reports it.

**Why compile in the browser rather than on a server?** The toolchain
is a few hundred kilobytes of wasm and runs in milliseconds. A server
would add latency, an availability dependency, and an attack surface,
to do work the client can do locally.

**Why share source rather than images?** A `.gx` is opaque and
version-bound. Source is readable, diffable, and rebuilt by the
recipient's toolchain — so a shared link keeps working across format
changes that would invalidate a blob.

**Why both languages from the start?** The lang compiler is the
larger half of the project. A playground that demonstrates only the
assembler would misrepresent what Gero is, and retrofitting a second
language into a UI built around one is more work than accommodating
both from the beginning.
