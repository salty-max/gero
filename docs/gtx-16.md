# gtx-16 — Fantasy Console Spec v0.1 (DRAFT)

The fantasy-console layer that consumes [Gero](./isa.md) as its CPU /
VM. gtx-16 defines: display peripheral, audio peripheral, input
peripheral, RNG, timing source, save backend, and the cart format
that wraps a `.gx` bytecode file plus assets.

> **Status: design draft.** Locks happen as the gtx-16 native runtime
> implementation forces decisions. Numbers in this doc are starting
> points, not final.

> **Layer separation:** gtx-16 lives in a separate repo (TBD —
> probably `salty-max/gtx-16`). It depends on the `gero` library for
> the VM kernel. This file lives in `gero/docs/` only because the
> two specs co-evolve closely and gero authors need the gtx-16
> contract handy. A future cleanup may move this to gtx-16's own
> docs.

---

## 1. Display

**Resolution:** 256×192, indexed-16-color (4 bpp).

Why 256×192:
- Wider than PICO-8 (128×128) — more room for J-RPG dialog boxes
  + map area side-by-side
- 4:3 aspect ratio (Game Boy was 10:9, NES 4:3)
- Power-of-two width simplifies tilemap math
- 192-pixel height = 24 rows of 8×8 tiles, divisible into 8-row
  status / 16-row map

**Color depth:** 4 bpp (16 colors visible at any time, palette
selectable from a 256-entry master).

**Framebuffer size:** `256 × 192 × 4 / 8 = 24 576 bytes (24 KB)`.

This is **larger** than the 16 KB mapped region A in gero's address
space. gtx-16 solves this by exposing the framebuffer through a
windowed mechanism, not direct memory mapping:

- The framebuffer lives **inside** the gtx-16 host (not in gero RAM)
- Writes go through IO registers in the IO page (`0xFF00..0xFFFF`)
- The 16 KB of mapped region A (`0x8000..0xBFFF`) is the
  **VRAM staging area** — tile patterns, tilemap, sprite OAM
  equivalent

This is the NES PPU model: VRAM separated from CPU RAM, accessed
through a small window of registers.

### 1.1 VRAM layout (mapped region A, 16 KB at `0x8000..0xBFFF`)

| Range | Size | Purpose |
|-------|------|---------|
| `0x8000..0x8FFF` | 4 KB | **Pattern table 0** — 256 tiles × 16 bytes (8×8 × 4 bpp = 32 bytes? — TBD on packing) |
| `0x9000..0x9FFF` | 4 KB | **Pattern table 1** — sprites |
| `0xA000..0xA7FF` | 2 KB | **Tilemap** — 32×32 cell grid, 2 bytes per cell (tile index + attributes) |
| `0xA800..0xABFF` | 1 KB | **Sprite OAM** — 64 sprites × 16 bytes (X, Y, tile index, attributes) |
| `0xAC00..0xAFFF` | 1 KB | **Palette** — 256 colors × 4 bytes (RGBA, A unused) |
| `0xB000..0xBFFF` | 4 KB | **Reserved** for v0.2 features (second tilemap layer? sample data?) |

These ranges are gtx-16-specific — they're not enforced by the gero
VM. A program that doesn't touch them sees plain RAM.

### 1.2 Display registers (in IO page)

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF00` | 1 | `DISPCTL` | bit 0: enable, bit 1: tilemap on, bit 2: sprites on, bit 3: window on |
| `0xFF01` | 1 | `SCROLL_X` | tilemap horizontal scroll (pixels) |
| `0xFF02` | 1 | `SCROLL_Y` | tilemap vertical scroll (pixels) |
| `0xFF03` | 1 | `PALETTE_INDEX` | sub-palette to apply to background (0..15) |

(More registers spec'd as the renderer implementation needs them.)

---

## 2. Audio

**4 channels:**
1. Square 1 (with duty cycle + envelope)
2. Square 2 (with duty cycle + envelope)
3. Triangle (no volume control, like NES)
4. Noise (for percussion / SFX)

NES APU model exactly. No DPCM in v0.1 — sample channel deferred.

**Sampling rate:** 44.1 kHz output (host-side); the VM ticks audio
registers at 60 Hz.

### 2.1 Audio registers (in IO page)

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF40` | 1 | `SQ1_VOL` | bits 0-3: volume (0-15), bits 4-5: duty cycle, bit 6: envelope decay |
| `0xFF41` | 2 | `SQ1_FREQ` | 11-bit frequency (lower 11 bits used) |
| `0xFF43` | 1 | `SQ2_VOL` | (same shape as SQ1) |
| `0xFF44` | 2 | `SQ2_FREQ` | |
| `0xFF46` | 2 | `TRI_FREQ` | triangle frequency |
| `0xFF48` | 1 | `NOISE_VOL` | volume + envelope |
| `0xFF49` | 1 | `NOISE_PERIOD` | noise period |
| `0xFF4A` | 1 | `CHAN_ENABLE` | bit 0: SQ1, 1: SQ2, 2: TRI, 3: NOISE |
| `0xFF4B` | 2 | `MUSIC_PTR` | start address of currently-playing music data (host audio engine reads + ticks) |

The "tracker" model: programs write a music-data pointer to
`MUSIC_PTR` and the host audio engine takes over — reading the
pattern data, ticking the synth, writing to the channel registers
60× per second. Programs can stop / pause / resume by writing 0 or
re-pointing.

---

## 3. Input

**Two gamepads** (Player 1, Player 2). Each:
- D-pad (4 directions)
- A, B (action buttons)
- Start, Select

8 bits per gamepad, polled per-frame.

### 3.1 Input registers (in IO page)

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF50` | 1 | `P1_STATE` | bits: 0=up, 1=down, 2=left, 3=right, 4=A, 5=B, 6=start, 7=select. 1 = pressed |
| `0xFF51` | 1 | `P2_STATE` | (same shape) |
| `0xFF52` | 1 | `P1_PREV` | previous frame's state — for edge detection (just-pressed = state & ~prev) |
| `0xFF53` | 1 | `P2_PREV` | |

The host updates these once per frame, before vblank. Programs read
freely.

---

## 4. RNG

A simple xorshift PRNG, host-managed, exposed via two registers:

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF60` | 2 | `RNG_OUT` | reading consumes a u16 from the stream and advances state |
| `0xFF62` | 2 | `RNG_SEED` | writing reseeds the stream (write-only; reads return last seed for debugging) |

PRNG is deterministic given a seed — useful for replays / save-state.
At boot, host seeds from wall-clock; programs can override.

---

## 5. Timing

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF70` | 2 | `FRAME_COUNTER` | u16le frame number since boot. Increments on vblank. Wraps at 65535 (≈ 18 minutes at 60 fps). |
| `0xFF72` | 1 | `VBLANK_FLAG` | 1 during vblank period, 0 during scan. Programs poll for sync. |

**Frame rate: 60 Hz.** Hard-locked. The VM runs at unbounded speed
between vblanks; programs synchronize to vblank for input + render.

A vblank IRQ fires on each frame transition (vector `0x06`,
host-defined per gtx-16). Programs that don't enable the IRQ can poll
`VBLANK_FLAG` instead.

---

## 6. Save backend

Implements the gero ISA SRAM-bank contract (gero spec §3.2.1).

**File location:** `<cart-name>.sav` next to the cart file. Plain
binary, contents = concatenation of the SRAM banks.

**Slot count:** 1 (single-slot saves in v0.1; multi-slot is a v0.2
feature that would need a save-slot syscall).

**Flush triggers:**
- Program exits cleanly (`hlt`).
- Program calls `int 0x21` (gero convention).
- Host-process receives shutdown signal (graceful close).
- Auto-flush every 30 seconds if any SRAM byte was written
  (insurance vs. crash).

**Format on disk:** raw bytes. No header, no version. Programs that
want versioning put it inside their SRAM data themselves (canonical
old-school). Mismatched save vs program version → program responsibility
to detect via its own header check.

---

## 7. Cart format (`.gtx`)

Wraps a `.gx` bytecode file plus assets and metadata.

```
[Header — 64 bytes]
0x00  magic            4   = 'GTX' '\x16' (0x47 0x54 0x58 0x16)
0x04  version          2   u16le format version (currently 0x0001)
0x06  title            32  UTF-8, null-padded
0x26  author           16  UTF-8, null-padded
0x36  flags            2   u16le bitfield
0x38  gx_offset        4   u32le offset of embedded .gx file
0x3C  gx_size          4   u32le size of embedded .gx in bytes

[Embedded .gx file at gx_offset for gx_size bytes]

[Optional asset section — TBD, e.g. tile pattern dumps, music data,
 sample data — formats designed alongside the editor / converter
 tooling that produces them]
```

The cart format is the **user-facing artifact** (what an end-user
double-clicks). The `.gx` inside is the executable image. Assets are
typically loaded by the VM on boot (program reads its own cart's
asset section via host-provided syscall).

Asset section design is **deferred** — needs to land alongside the
gtx-16 editor / converter tools, which don't exist yet.

---

## 8. Boot sequence

1. gtx-16 host loads `.gtx` cart.
2. Validates magic + version.
3. Extracts embedded `.gx` to a buffer.
4. Initializes a gero VM:
   - Allocates 64 KB RAM
   - Maps display device at `0x8000..0xBFFF` (VRAM staging)
   - Maps IO device at `0xFF00..0xFFFF` (peripheral registers)
   - Loads `.gx` image into RAM `0x0000..image_size`
   - Loads SRAM banks from `<cart>.sav` if present
   - Sets `ip = entry_point` from `.gx` header
5. Begins fetch-decode-execute loop, ticking display + audio + input
   peripherals on schedule.

---

## 9. What gtx-16 explicitly does NOT do

To keep the layering clean, gtx-16 does not provide:

- **File I/O beyond saves.** Programs can't open arbitrary files.
  All asset access goes through the cart's bundled asset section.
- **Network I/O.** Single-machine console, no online play in v0.1.
- **Direct OS calls.** No `system()`, no clipboard, no clock-time
  beyond the frame counter.
- **Custom CPU extensions.** The CPU is gero, period. No coprocessor
  registers, no custom opcodes.

These constraints are deliberate — they're what makes gtx-16 a
fantasy console rather than "another scripting environment".

---

## 10. Open questions (resolve as the renderer + audio engine land)

- Tile pattern packing (4 bpp planar like NES, or chunky 4 bpp?)
- Sprite priority + occlusion (per-sprite priority bits, or strict
  back-to-front by OAM order?)
- Audio register write throttling (avoid write storms causing
  clicks)
- Save-file naming convention (relative path, slot suffixes, etc.)
- Multi-cart workflow (carts that load other carts? or one cart per
  session?)
