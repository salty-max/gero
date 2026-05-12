# gtx-16 — Fantasy Console Spec v0.2 (DRAFT)

The fantasy-console layer that consumes [Gero](./isa.md) as its CPU /
VM. gtx-16 defines: display peripheral, audio peripheral, input
peripheral, RNG, timing source, save backend, the cart format that
wraps a `.gx` bytecode file plus assets, the filesystem, the shell,
and the built-in editor suite.

> **Status: design draft.** Specifies the target shape; locks happen
> as the gtx-16 native runtime implementation forces decisions.
> Numbers and IO addresses are starting points, not final.

> **Layer separation:** gtx-16 lives in a separate repo (TBD —
> probably `salty-max/gtx-16`). It depends on the `gero` library for
> the VM kernel. This file lives in `gero/docs/` only because the
> two specs co-evolve closely and gero authors need the gtx-16
> contract handy. A future cleanup may move this to gtx-16's own
> docs.

> **What changed since v0.1.** v0.1 modeled the display as an
> NES-style PPU (tiles + sprites + tilemap). v0.2 switches to a
> Picotron-class linear framebuffer with host-side drawing
> primitives. The gero VM is **unchanged** — all impact is on
> gtx-16's host implementation. See §16 for the rationale.

---

## 1. Display

**Resolution:** 320×240 at 6 bpp (64 visible colors), 4:3 aspect.

Why this shape:
- 4:3 retro-PC feel (VGA Mode 13h was 320×200; 320×240 is the
  square-pixel cousin used by Mode-X and many DOS games)
- 320×240 = 76800 pixels = 57.6 KB framebuffer @ 6 bpp packed —
  fits comfortably in host RAM, doesn't try to spill into the
  16-bit gero address space
- 64 visible colors out of a 256-entry master palette is the sweet
  spot between 8-bit charm (PICO-8's 16) and 16-bit polish (SNES's
  256 — overkill for the visual identity we're after)

### 1.1 Framebuffer model

Two **linear** framebuffers (no tile/sprite hardware):

| Layer | Role |
|-------|------|
| **Layer 0 — background** | Game world. Drawn first. |
| **Layer 1 — foreground** | HUD, dialog, menus. Drawn over layer 0. |

Both layers are 320×240 × 6 bpp, lived **inside the host** — not
exposed to gero's address space. The cart drives drawing via the
**IO command surface** (§2). One color in the foreground layer is
reserved as the transparency key (default: palette index 0) — the
host composites layer 0 visible through transparent pixels of
layer 1.

This is **not** the NES/SNES PPU model. There are no tile pattern
tables, no tilemap registers, no sprite OAM. "Tilemaps" and
"sprites" are achieved via the drawing primitives (§2): blit a
sprite, draw a rect, etc. The host implements those primitives in
native code so the cart pays one opcode for what would be hundreds
of cycles in raw gero.

### 1.2 Palette + color tables

**Palette:** 256-entry master, 64 entries visible at any time.

| Address | Field | Description |
|---------|-------|-------------|
| `0xFF00..0xFFFF` (host) | `master_palette` | 256 × 4 bytes (RGB + reserved). Initialized at cart load; can be modified at runtime. |
| `0xFE00..0xFE3F` | `display_palette` | 64 × 1 byte. Each entry maps a "visible color N" to a "master palette index M". Changing this remaps colors on-screen without redrawing. |

**Color tables (LUTs):** Picotron-style. A color table is a 64-byte
LUT that maps each visible-color index to another. Up to 8 active
LUTs are addressable; one is selected as "current" during draws.
When the current LUT is set to identity (color N → color N), draws
write through unchanged. Other LUTs enable:

- **Distance shading** (Doom fade): write a LUT that darkens by one
  step. Apply during far-distance draws.
- **Sprite recolor**: same sprite, different palette via a LUT that
  remaps the sprite's color set.
- **Whole-screen fade-to-black**: cycle through a sequence of LUTs
  each frame.
- **Transparency / blending**: the LUT can pre-compute the
  source × destination color blend for additive / dim / silhouette
  effects.

LUTs are stored in a small dedicated region of host RAM (8 LUTs ×
64 bytes = 512 bytes). The cart uploads them via a dedicated IO
command (`gpu lut_upload`, §2).

### 1.3 Display registers (in IO page)

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFE40` | 1 | `DISPCTL` | bit 0: display enable, bit 1: layer 0 visible, bit 2: layer 1 visible, bit 3: vsync wait |
| `0xFE41` | 1 | `ACTIVE_LAYER` | 0 = subsequent draws hit layer 0, 1 = layer 1 |
| `0xFE42` | 1 | `ACTIVE_LUT` | 0..7 — which color table to apply to subsequent draws (0 = identity) |
| `0xFE43` | 1 | `TRANSPARENT_IDX` | Visible-color index treated as transparent in layer 1 (default 0) |
| `0xFE44..0xFE47` | 4 | `CLIP_RECT` | x0, y0, x1, y1 — drawing is clipped to this box (default: full screen) |
| `0xFE48..0xFE4B` | 4 | `CAMERA` | i16le camera_x, camera_y — translates all subsequent draw positions |

---

## 2. Drawing primitives (IO command surface)

Drawing is done by writing **commands** to a fixed IO command
region. The host watches that region; when the trigger register is
written, the command executes with the staged parameters.

### 2.1 Command layout

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFE50..0xFE5F` | 16 | `CMD_PARAMS` | Up to 16 bytes of staged parameters (interpretation depends on opcode) |
| `0xFE60` | 1 | `CMD_OPCODE` | Which primitive to execute |
| `0xFE61` | 1 | `CMD_TRIGGER` | Writing any value triggers execution with the staged params + opcode |

The cart's typical pattern:

```asm
; Draw a filled rect: rectfill(10, 20, 50, 60, color=7)
mov $0A, &FE50         ; x0 = 10
mov $14, &FE51         ; y0 = 20
mov $32, &FE52         ; x1 = 50
mov $3C, &FE53         ; y1 = 60
mov $07, &FE54         ; color = 7
mov $02, &FE60         ; OPCODE_RECTFILL = 0x02
mov $01, &FE61         ; trigger
```

In practice, a future high-level macro layer (the `gero-lang`
compiler will expose this) lets you write `rectfill(10, 20, 50, 60,
7)` and the macro expands to the byte sequence above.

### 2.2 Command opcodes

| Opcode | Name | Params (byte layout in CMD_PARAMS) |
|--------|------|------------------------------------|
| `0x00` | `cls` | u8 color — fill the active layer with `color`. |
| `0x01` | `pset` | u16le x, u16le y, u8 color |
| `0x02` | `rectfill` | u16le x0, u16le y0, u16le x1, u16le y1, u8 color |
| `0x03` | `rect` | same as rectfill but stroke only |
| `0x04` | `line` | u16le x0, u16le y0, u16le x1, u16le y1, u8 color |
| `0x05` | `circle` | u16le cx, u16le cy, u8 radius, u8 color |
| `0x06` | `circfill` | same |
| `0x10` | `spr` | u16le sprite_idx, u16le x, u16le y, u8 flags (bit 0: hflip, bit 1: vflip) |
| `0x11` | `spr_scaled` | u16le sprite_idx, u16le x, u16le y, u8 w_tiles, u8 h_tiles |
| `0x12` | `spr_sized` | u16le sprite_idx, u16le x, u16le y, u16le dst_w, u16le dst_h |
| `0x20` | `print` | u16le str_addr, u16le x, u16le y, u8 color (str_addr → null-terminated bytes in cart memory) |
| `0x30` | `lut_upload` | u8 lut_idx (0..7), u16le src_addr (64 bytes of LUT data in cart memory) |
| `0x31` | `palette_upload` | u16le src_addr (256×4 bytes), u8 count (how many entries from 0) |
| `0x40` | `blit_layer` | u8 src_layer, u8 dst_layer — copy one whole layer to the other |

(More opcodes land as the runtime matures — see §16 open
questions.)

### 2.3 Sprite storage

Sprites live in the cart's memory at a region the cart chooses.
The `spr` family of commands takes a `sprite_idx` which the host
interprets via a sprite-sheet base register:

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFE70..0xFE71` | 2 | `SPRITESHEET_BASE` | u16le — base address in cart memory where sprite 0 starts |
| `0xFE72` | 1 | `SPRITE_SIZE` | 0 = 8×8, 1 = 16×16, 2 = 32×32 (per-cart constant; can be changed at runtime) |

A sprite is `(size × size × 6 / 8)` bytes packed. For 8×8 × 6 bpp,
that's 48 bytes per sprite. With a 16 KB region allocated, the
cart fits 16384/48 ≈ 341 sprites.

The cart can dynamically reupload sprite data at runtime (modify
the bytes at `SPRITESHEET_BASE + sprite_idx × stride`) — host
re-reads on next draw.

---

## 3. Audio

8 channels, tracker-style mix.

### 3.1 Channel types

Each channel can be one of:

| Type | Description |
|------|-------------|
| `square` | Pulse wave with 4 duty options (12%, 25%, 50%, 75%) |
| `triangle` | Anti-aliased triangle wave |
| `sawtooth` | Saw wave (down or up) |
| `noise` | Pseudo-random noise (short / long period) |
| `pcm` | 8-bit signed PCM sample, ~8 KHz typical rate |

Each channel has independent: frequency, volume, optional ADSR
envelope, optional volume LFO, optional pitch LFO, pan
(left/center/right).

### 3.2 Channel registers (in IO page)

Per channel `N` (0..7), base at `0xFE80 + N × 8`:

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| `+0` | 1 | `TYPE` | bits 0-2: waveform (0..4 per above), bit 7: enable |
| `+1` | 1 | `VOLUME` | 0..63 |
| `+2..+3` | 2 | `FREQ` | u16le frequency in Hz |
| `+4` | 1 | `DUTY_OR_NOISE` | for square: duty bits 0-1; for noise: long/short period bit |
| `+5` | 1 | `PAN` | i8: -64 (full left) to +63 (full right) |
| `+6..+7` | 2 | `ENV_OR_SAMPLE` | u16le — envelope descriptor index OR PCM sample index (depends on TYPE) |

So 8 channels × 8 bytes = 64 bytes total for channel state, at
`0xFE80..0xFEBF`.

### 3.3 Tracker / pattern playback (optional layer)

The host exposes a built-in tracker engine that can play patterns
(sequences of notes, instruments, effects) without the cart
manually setting channel registers each frame. The cart uploads a
"song" data structure and tells the engine to play it. The engine
runs on the host (no gero opcodes burned).

Tracker IO:

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFEC0..0xFEC1` | 2 | `SONG_ADDR` | u16le pointer to a Song struct in cart memory |
| `0xFEC2` | 1 | `SONG_CTL` | bit 0: play, bit 1: loop, bit 2: stop |
| `0xFEC3` | 1 | `SONG_VOLUME` | 0..63 master volume |

The Song struct format is TBD — pinned in the next gtx-16 spec
revision once the audio engine prototype lands.

---

## 4. Input

Gamepad **and** keyboard **and** mouse, all first-class. Carts can
poll any or all.

### 4.1 Gamepad

8 buttons: Up, Down, Left, Right, A, B, X, Y. Mapped to keyboard
arrows + Z/X/A/S by default; remappable.

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFEE0` | 1 | `BTN_STATE` | bits 0-7: pressed-this-frame state per button |
| `0xFEE1` | 1 | `BTN_PRESSED` | edge-triggered: 1 if pressed this frame and not last |
| `0xFEE2` | 1 | `BTN_RELEASED` | edge-triggered: 1 if released this frame |

(For multi-player carts, the spec reserves `0xFEE3..0xFEE5` for
players 2/3/4 — registered when actual gamepads land.)

### 4.2 Keyboard

The host exposes a small key buffer the cart can drain:

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFEE8..0xFEE9` | 2 | `KEY_BUF_HEAD` | u16le — index of next available char (write to advance) |
| `0xFEEA..0xFEEB` | 2 | `KEY_BUF_TAIL` | u16le — index of oldest unread char (host writes) |
| `0xFEEC` | 1 | `KEY_MODIFIERS` | bits 0: shift, 1: ctrl, 2: alt, 3: meta |
| `0xFEED..0xFEFF` | 19 | `KEY_BUF` | Ring buffer of u8 chars (ASCII for typeable, control codes for arrows/etc.) |

For raw key-state polling (e.g., "is W currently down?"), a
separate `KEY_DOWN` register set is reserved for the next revision.

### 4.3 Mouse

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF00..0xFF01` | 2 | `MOUSE_X` | u16le pixel X (0..319) |
| `0xFF02..0xFF03` | 2 | `MOUSE_Y` | u16le pixel Y (0..239) |
| `0xFF04` | 1 | `MOUSE_BTNS` | bits 0: left, 1: right, 2: middle |
| `0xFF05` | 1 | `MOUSE_WHEEL` | i8 wheel delta this frame |

---

## 5. RNG

Single 16-bit linear-feedback shift register. Carts can seed it
manually or let the host seed from wall-clock at boot.

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF08..0xFF09` | 2 | `RNG_VALUE` | u16le current value; reading auto-advances |
| `0xFF0A..0xFF0B` | 2 | `RNG_SEED` | u16le seed (writable) |

---

## 6. Timing

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF10..0xFF11` | 2 | `FRAME_COUNTER` | u16le frame number since boot. Increments on vblank. Wraps at 65535. |
| `0xFF12` | 1 | `VBLANK_FLAG` | 1 during vblank, 0 during scan |
| `0xFF13` | 1 | `TARGET_FPS` | 60 by default; can be set to 30 for slower carts |

**Frame rate: 60 Hz** (or 30 Hz if `TARGET_FPS` is set). The VM
runs as fast as the host allows between vblanks — no artificial
cap. A cart that doesn't finish its frame's work before the next
vblank just drops frames; the host displays the fps drop.

A vblank IRQ fires on each frame transition (vector `0x06` per ISA
§6).

---

## 7. Persistence + save backend

Implements the gero ISA SRAM-bank contract (gero spec §3.2).

Carts that declare `sram_bank_count > 0` get persistent storage:
each SRAM bank is 16 KB, save data is bound to `/data/<cart_name>/`
in the filesystem. The host writes-through to disk on every `vsync`
or on explicit cart request.

For non-banked carts that want lightweight persistent data (high
scores, settings), the host exposes `KV_STORE` IO commands:

| Address | Size | Field | Description |
|---------|------|-------|-------------|
| `0xFF20..0xFF21` | 2 | `KV_KEY_ADDR` | u16le pointer to a null-terminated key string in cart memory |
| `0xFF22..0xFF23` | 2 | `KV_VALUE_ADDR` | u16le pointer to value bytes |
| `0xFF24..0xFF25` | 2 | `KV_VALUE_LEN` | u16le length of value bytes |
| `0xFF26` | 1 | `KV_OP` | 0: get, 1: set, 2: delete |
| `0xFF27` | 1 | `KV_TRIGGER` | write to execute |

Stored as a small JSON file at `/data/<cart_name>/kv.json`.

---

## 8. Cart format (`.gtx`)

A cart is an archive containing the bytecode plus assets. Three
formats coexist:

### 8.1 `.gtx` (binary archive)

The packaged format — what gets loaded by the shell's `run`
command. Layout:

```
[Header — 24 bytes]
[gero .gx image — image_size bytes]
[Banks — bank_count × 16384 bytes] (if banked)
[SRAM banks — sram_bank_count × 16384 bytes] (initial values)
[Sprite sheets — variable, concatenated]
[Sound assets — synth presets + PCM samples]
[Metadata block — JSON: title, author, version, ...]
```

Header:

| Offset | Size | Field |
|--------|------|-------|
| `0x00` | 4 | Magic = `"GTX1"` (ASCII) |
| `0x04` | 2 | u16le version = `0x0002` |
| `0x06` | 2 | u16le flags |
| `0x08` | 2 | u16le entry point |
| `0x0A` | 2 | u16le image_size |
| `0x0C` | 1 | u8 bank_count |
| `0x0D` | 1 | u8 sram_bank_count |
| `0x0E` | 2 | u16le sprites_offset (from start of archive) |
| `0x10` | 2 | u16le audio_offset |
| `0x12` | 2 | u16le metadata_offset |
| `0x14..0x17` | 4 | reserved (must be 0) |

### 8.2 `.gas` / `.gr` (source carts)

If the cart is shipped as source (`.gas` for asm, `.gr` for the
future gero-lang), the shell auto-assembles / auto-compiles it at
`run` time. Built artifacts get cached at `/tmp/build/<hash>.gtx`
so subsequent runs are instant.

Source carts are a single file convention:

```
/carts/breakout.gas       ; single source file
/carts/breakout_src/      ; multi-file project
    main.gas
    sprites.gfx           ; raw binary sprite data
    music.sfx
    cart.toml             ; project manifest (title, version, etc.)
```

### 8.3 `.gtx.png` (shareable PNG)

A PICO-8 / Picotron-style sharing format: the cart's bytes are
encoded into the pixel data of a PNG image, with the image itself
showing a screenshot or title screen. Upload anywhere that
accepts images; anyone can drag the PNG back into the console to
play.

```
> save my_game.gtx.png
encoded 89 KB cart into a 320x240 PNG
PNG includes a screenshot from last frame as the cover image

> ls
my_game.gtx          ; local binary
my_game.gtx.png      ; share-friendly version
```

---

## 9. Filesystem

Simple hierarchy with pre-defined root directories. Unix-style
paths with `/` separator. No multi-user concept.

```
/
├── carts/        ; user-installed + locally-built carts
│   ├── games/
│   ├── tools/
│   └── *.gtx, *.gas, *.gr
├── data/         ; persistent data (save files, screenshots,
│                  ;                kv stores)
│   ├── breakout/
│   │   ├── kv.json
│   │   └── sram_0.bin
│   └── tetris/
│       └── high_scores.txt
├── sys/          ; read-only system stuff
│   ├── boot.gtx          ; the boot shell itself
│   ├── editors/          ; built-in editor carts
│   ├── fonts/
│   └── palettes/         ; system palette presets
└── tmp/          ; scratch, cleared on every boot
    └── build/            ; cached source-cart builds
```

The host maps `/` to a real directory on the OS filesystem
(typically `~/.gtx-16/` on Unix, `%APPDATA%\gtx-16\` on Windows).

Operations are sandboxed: a cart cannot escape `/data/<cart_name>/`
when writing. Reads from `/carts/` and `/sys/` are allowed; reads
from other carts' `/data/` regions are not.

---

## 10. Shell

PICO-8-minimal style. Boot drops the user at a prompt.

### 10.1 Built-in commands

| Command | Description |
|---------|-------------|
| `help [topic]` | Help on a command or topic. |
| `ls [path]` | List directory. Defaults to current. |
| `cd <path>` | Change directory. |
| `pwd` | Print working directory. |
| `mkdir <path>` | Create a directory. |
| `rm <path>` | Delete a file. Refuses on non-empty directories without `-r`. |
| `mv <src> <dst>` | Move / rename. |
| `cp <src> <dst>` | Copy. |
| `cat <path>` | Print a file. |
| `clear` | Clear the screen. |
| `load <cart>` | Load a cart into memory (no run). |
| `run [cart]` | Run loaded cart, or `run <cart>` to load + run. |
| `save [name]` | Save the current cart (with optional rename). |
| `edit [editor]` | Open an editor on the current cart. Default: code. See §11. |
| `splore` | Open a graphical browser of available carts. |
| `screenshot` | Capture current frame to `/data/<cart>/screenshots/N.png`. |
| `boot <cart>` | Set a cart to auto-run on next boot. |
| `reboot` | Restart the console. |

No pipes, no redirection, no scripting. The shell is for
navigation + launching, not for building automation. (If you want
automation, write a cart.)

### 10.2 Prompt

```
gtx-16 v0.2.0
type 'help' for commands, 'splore' to browse carts

/> _
```

### 10.3 Tab completion

Path tab completion on file/directory args. Command tab completion
on the first token.

---

## 11. Built-in editors

Six editors, all reachable from the shell or via function keys
when a cart is loaded.

| Command | Hotkey | Editor |
|---------|--------|--------|
| `edit code` | F1 | Code editor (text). Edits `.gas` / `.gr` source. |
| `edit sprites` | F2 | Sprite sheet editor. 8×8 / 16×16 / 32×32 cell grid with paint tools. |
| `edit sfx` | F3 | Sound effect editor. Per-channel parameter tweaker + preview. |
| `edit music` | F4 | Music tracker. Pattern grid, ~64 rows × 4-8 tracks. |
| `edit map` | F5 | Tilemap editor (for carts that use tile-based level data — stored as cart bytes since there's no hardware tilemap). |
| `edit palette` | F6 | Palette editor. Tweak the 256 master colors and the 64 visible mapping. |

Editors are themselves carts (`/sys/editors/*.gtx`). They run the
same VM as any other cart, just with privileged access to the
loaded cart's memory + assets. This means anyone can write their
own editor and drop it in `/sys/editors/` to extend the suite.

All editors share:

- `Esc` returns to the shell.
- `Ctrl+S` saves the current cart.
- `F11` switches to fullscreen.
- The tab bar across the top lets you switch editors without
  going back to the shell.

---

## 12. Boot sequence

1. Host loads VM + maps display, audio, input devices.
2. Host loads `/sys/boot.gtx` (the boot shell) and runs it.
3. The boot shell:
   - Clears `/tmp/`.
   - Reads `/sys/boot.cfg` (if present) for theme, autorun cart,
     remappings, etc.
   - Drops the user at the prompt — OR auto-runs `boot.cfg.autorun`
     if set.
4. From there, the user runs carts via `run`.

A cart can call `host_reboot()` (gero opcode) to relaunch the
boot shell at any point.

---

## 13. What gtx-16 explicitly does NOT do

- **No 3D acceleration.** Software 3D is possible if a cart wants
  to do it; nothing helps.
- **No floating-point.** gero ISA is integer-only. Carts that need
  FP roll their own fixed-point.
- **No networking.** No sockets, no URL fetch, no BBS browser
  inside the console. Sharing happens via `.gtx.png` export +
  upload to whatever service you like.
- **No multi-process.** One cart runs at a time. The shell
  suspends when a cart starts; resumes when the cart exits.
- **No clipboard / direct OS calls.** No `system()`, no shell-out,
  no opening arbitrary files outside the sandbox.
- **No timed real-world clock.** Frame counter only — no calendar
  time exposed (deterministic by design).
- **No GPU shaders** beyond what color tables provide.

---

## 14. Memory map summary

The host claims the following gero IO page ranges:

| Range | Purpose | §  |
|-------|---------|----|
| `0xFE40..0xFE4B` | Display registers | §1.3 |
| `0xFE50..0xFE61` | Drawing command surface | §2 |
| `0xFE70..0xFE72` | Sprite sheet config | §2.3 |
| `0xFE80..0xFEBF` | Audio channel state (8 × 8 bytes) | §3.2 |
| `0xFEC0..0xFEC3` | Tracker / song playback | §3.3 |
| `0xFEE0..0xFEE2` | Gamepad | §4.1 |
| `0xFEE8..0xFEFF` | Keyboard | §4.2 |
| `0xFF00..0xFF05` | Mouse | §4.3 |
| `0xFF08..0xFF0B` | RNG | §5 |
| `0xFF10..0xFF13` | Timing | §6 |
| `0xFF20..0xFF27` | KV store | §7 |

Total: ~192 bytes of IO page used; ~64 bytes reserved for the
next round of additions.

---

## 15. Roadmap (post-v0.2)

| Feature | Why |
|---------|-----|
| Rotation primitives (`spr_rotated`, full affine matrix) | If user demand emerges. v0.2 has scale only. |
| Per-scanline palette / palette HDMA equivalent | Sky gradients, atmospheric effects. Easy to add later. |
| Multi-process / background music while editing | Optional — would push the project toward "fantasy workstation" identity vs "fantasy console". |
| Network access (read-only BBS) | If a curated cart-sharing platform makes sense. Sandbox stays strict. |
| Higher resolutions (480×270, 640×480) | Possibly a `RESOLUTION` register that the cart picks at load. Trade-off: bigger FB, more pixel-pushing per frame. |

---

## 16. Why this shape (rationale notes)

A few decisions worth pinning down so future-me doesn't relitigate
them:

- **Why 320×240 and not 480×270?** 4:3 retro PC feel beats 16:9
  modern for the visual identity we want. 320×240 is the VGA
  Mode-X cousin — DOS-era games visually. 480×270 is more modern
  but loses the "early 90s" charm.
- **Why linear FB and not PPU?** v0.1's PPU design ruled out
  raycasters and made software-rendered effects much harder. The
  Picotron model (linear FB + host-side drawing primitives)
  delivers more creative ceiling at similar implementation cost.
  See conversation log in PR #80 for the full reasoning.
- **Why no rotation primitive in v0.2?** Implementation cost (bilinear
  sampling, careful clipping) for a feature most carts don't need.
  Sprite sheets with pre-rotated frames cover 90% of the use case.
  Adding rotation later is non-breaking.
- **Why "no networking" is a feature, not a missing piece.** The
  sandbox is tight by design — no exfiltration risk, no version-
  dependent online dependencies, no rotting BBS URLs five years
  from now. Sharing via PNG is enough.
- **Why a 2-layer model and not 1 (Picotron) or 4 (SNES)?** One
  layer is too tight for HUDs over scrolling games. Four layers is
  SNES-mode-1 overkill. Two strikes the balance and the
  compositing cost is constant.
- **Why color tables and not arbitrary shaders?** Color tables are
  cheap (64 byte LUT, one indirection per pixel during draw) and
  cover most of the "shader" use cases (shading, recolor,
  blending). Arbitrary shaders would balloon the host implementation
  and bind the spec to a GPU model.

---

## 17. Versioning

This is gtx-16 v0.2. Locking it requires:
- Pinning the Song struct layout (§3.3)
- Pinning the cart `.gtx.png` encoding scheme (§8.3)
- Pinning the editor cart contracts (§11)
- Pinning the `.gas` / `.gr` source-cart auto-build flow (§8.2)

These will iterate as the gtx-16 host implementation lands.
gero v0.1 doesn't depend on any of this.
