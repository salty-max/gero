import { assemble, machineCodeAsHex } from '../assembler'
import { CPU, MemoryMapper, createRAM, createROM } from '../vm'
import {
  BACKGROUND_OFFSET,
  CODE_OFFSET,
  CYCLES_PER_ANIMATION_FRAME,
  FOREGROUND_OFFSET,
  INPUT_SIZE,
  INTERRUPT_VECTOR_OFFSET,
  MAX_SPRITES,
  PIXELS_PER_TILE,
  RAM1_SIZE,
  RAM2_SIZE,
  SPRITE_SIZE,
  SPRITE_TABLE_OFFSET,
  TILES_X,
  TILES_Y,
  TILE_MEMORY_SIZE,
  TILE_SIZE,
  TIME_PER_FRAME_MS,
} from './config'
import { Renderer, Tile } from './graphics'

class Game {
  private programPath: string
  private tileMemory = createROM(TILE_MEMORY_SIZE)
  private RAMSegment1 = createRAM(RAM1_SIZE)
  private inputMemory = createROM(INPUT_SIZE)
  private RAMSegment2 = createRAM(RAM2_SIZE)
  private MM = new MemoryMapper()
  private tileCache: Tile[] = []
  private inputStates = [
    0 /* UP */, 0 /* DOWN */, 0 /* LEFT */, 0 /* RIGHT */, 0 /* A */, 0 /* B */,
    0 /* START */, 0 /* SELECT */,
  ]
  private cpu!: CPU
  private renderer!: Renderer
  private last = Date.now()

  constructor(programPath: string) {
    this.programPath = programPath
    this.init()
  }

  private async init() {
    // Prepare memory mapper
    this.MM.map(this.tileMemory, 0x0000, TILE_MEMORY_SIZE)
    this.MM.map(this.RAMSegment1, 0x2000, RAM1_SIZE)
    this.MM.map(this.inputMemory, 0x2620, INPUT_SIZE)
    this.MM.map(this.RAMSegment2, 0x2628, RAM2_SIZE)

    // Prepare tiles
    this.prepareTiles()

    // Setup game code
    await this.setupGameCode()

    // Prepare canvas
    this.renderer = new Renderer()

    // Listen for keyboard events
    document.addEventListener('keydown', this.handleKeydown.bind(this))

    this.last = Date.now()
    // Start the game loop
    this.draw()
  }

  private fullColourTile(colour: number) {
    return Array.from({ length: TILE_SIZE }, () => (colour << 4) | colour)
  }

  private prepareTiles() {
    const tiles = []
    for (let i = 0; i < 16; i++) {
      tiles.push(...this.fullColourTile(i))
    }
    /* prettier-ignore */
    tiles.push(
      0x11, 0x11, 0x11, 0x11,
      0x10, 0x00, 0x00, 0x01,
      0x10, 0x00, 0x00, 0x01,
      0x10, 0x00, 0x00, 0x01,
      0x10, 0x00, 0x00, 0x01,
      0x10, 0x00, 0x00, 0x01,
      0x10, 0x00, 0x00, 0x01,
      0x11, 0x11, 0x11, 0x11,
    );

    // Frog
    /* prettier-ignore */
    tiles.push(
      0xbb, 0xbb, 0x00, 0x00,
      0x00, 0xb7, 0xb0, 0x00,
      0xbb, 0xbb, 0xbb, 0x00,
      0x00, 0x0b, 0xbb, 0x00,
      0x00, 0xbb, 0xbb, 0x00,
      0x0b, 0x0b, 0xbb, 0xb0,
      0x00, 0x0b, 0xb0, 0xb0,
      0x0b, 0xbb, 0x00, 0xbb
    )

    // Frog hurt
    /* prettier-ignore */
    tiles.push(
      0x88, 0x88, 0x00, 0x00,
      0x00, 0x87, 0x80, 0x00,
      0x88, 0x88, 0x88, 0x00,
      0x00, 0x08, 0x88, 0x00,
      0x00, 0x88, 0x88, 0x00,
      0x08, 0x08, 0x88, 0x80,
      0x00, 0x08, 0x80, 0x80,
      0x08, 0x88, 0x00, 0x88
    )

    // Elephant
    /* prettier-ignore */
    tiles.push(
      0x00, 0x00, 0x66, 0x00,
      0x00, 0x66, 0x66, 0x60,
      0x06, 0x66, 0x66, 0x06,
      0x66, 0x66, 0x66, 0x66,
      0x66, 0x66, 0x67, 0x76,
      0x66, 0x66, 0x66, 0x06,
      0x06, 0x60, 0x66, 0x06,
      0x06, 0x70, 0x67, 0x06
    );

    // Elephant flipped
    /* prettier-ignore */
    tiles.push(
      0x00, 0x66, 0x00, 0x00,
      0x06, 0x66, 0x66, 0x00,
      0x60, 0x66, 0x66, 0x60,
      0x66, 0x66, 0x66, 0x66,
      0x67, 0x76, 0x66, 0x66,
      0x60, 0x66, 0x66, 0x66,
      0x60, 0x66, 0x06, 0x60,
      0x60, 0x76, 0x07, 0x60
    );
    this.tileMemory.load(tiles)

    for (let y = 0; y < TILES_Y; y++) {
      for (let x = 0; x < TILES_X; x++) {
        if ([4, 5].includes(y)) {
          this.MM.setUint8(BACKGROUND_OFFSET + x + y * TILES_X, 0x0c)
        } else {
          this.MM.setUint8(BACKGROUND_OFFSET + x + y * TILES_X, 0x03)
        }
      }
    }

    // for (let i = 0; i < TILES_X * TILES_Y; i++) {
    //   this.MM.setUint8(BACKGROUND_OFFSET + i, 0x10)
    // }

    const frog = SPRITE_TABLE_OFFSET
    this.MM.setUint16(frog + 0, 7 * PIXELS_PER_TILE + 4)
    this.MM.setUint16(frog + 2, 15 * PIXELS_PER_TILE - 4)
    this.MM.setUint8(frog + 4, 0x11)

    const elephants = frog + SPRITE_SIZE

    const makeElephant = (
      x: number,
      y: number,
      vx: number,
      index = 0,
      flip = false
    ) => {
      this.MM.setUint16(
        elephants + SPRITE_SIZE * index + 0,
        x * PIXELS_PER_TILE
      )
      this.MM.setUint16(
        elephants + SPRITE_SIZE * index + 2,
        y * PIXELS_PER_TILE
      )
      this.MM.setUint8(elephants + SPRITE_SIZE * index + 4, flip ? 0x14 : 0x13)
      this.MM.setUint16(
        elephants + SPRITE_SIZE * index + 9,
        flip ? (~vx & 0xffff) + 1 : vx
      )
    }

    makeElephant(4, 12, 3)
    makeElephant(15, 10, 3, 1, true)
    makeElephant(8, 8, 3, 2)

    for (let i = 0; i < TILE_MEMORY_SIZE; i += TILE_SIZE) {
      this.tileCache.push(new Tile(this.tileMemory.slice(i, i + TILE_SIZE)))
    }
  }

  private async setupGameCode() {
    const { machineCode, symbols } = await assemble(
      this.programPath,
      CODE_OFFSET
    )

    console.log(`Assembled machine code (${machineCode.length} bytes)`)
    console.log(machineCodeAsHex(machineCode))

    machineCode.forEach((byte: number, i: number) =>
      this.MM.setUint8(CODE_OFFSET + i, byte)
    )

    this.MM.setUint16(INTERRUPT_VECTOR_OFFSET, CODE_OFFSET)
    this.MM.setUint16(INTERRUPT_VECTOR_OFFSET + 2, symbols.after_frame)

    this.cpu = new CPU(this.MM, INTERRUPT_VECTOR_OFFSET)
    //this.cpu.setDebugMode(true)
  }

  private handleKeydown(e: KeyboardEvent) {
    switch (e.key) {
      case 'ArrowUp':
        this.inputStates[0] = 1
        break
      case 'ArrowDown':
        this.inputStates[1] = 1
        break
      case 'ArrowLeft':
        this.inputStates[2] = 1
        break
      case 'ArrowRight':
        this.inputStates[3] = 1
        break
      case 'a':
        this.inputStates[4] = 1
        break
      case 'b':
        this.inputStates[5] = 1
        break
      case 'Enter':
        this.inputStates[6] = 1
        break
      case 'Shift':
        this.inputStates[7] = 1
        break
    }

    this.inputMemory.load(this.inputStates)
  }

  private draw() {
    const now = Date.now()
    const dt = now - this.last

    if (dt > TIME_PER_FRAME_MS) {
      this.last = now

      this.inputMemory.load(this.inputStates) // Load the current state of the input into the input memory
      // Reset the state of the input
      for (let i = 0; i < this.inputStates.length; i++) {
        this.inputStates[i] = 0
      }

      this.renderer.clear()

      // Render the background tiles
      for (let i = 0; i < TILES_X * TILES_Y; i++) {
        const x = i % TILES_X
        const y = Math.floor(i / TILES_X)
        const tile = this.tileCache[this.MM.getUint8(BACKGROUND_OFFSET + i)]
        this.renderer.drawGridAlignedTile(x, y, tile)
      }

      // Render the sprites
      for (let i = 0; i < MAX_SPRITES; i++) {
        const spriteBase = SPRITE_TABLE_OFFSET + i * SPRITE_SIZE
        const x = this.MM.getUint16(spriteBase + 0)
        const y = this.MM.getUint16(spriteBase + 2)
        const tile =
          this.MM.getUint8(spriteBase + 4) + this.MM.getUint8(spriteBase + 5)
        this.renderer.drawPixelAlignedTile(x, y, this.tileCache[tile])
      }

      // Render the foreground tiles
      for (let i = 0; i < TILES_X * TILES_Y; i++) {
        const x = i % TILES_X
        const y = Math.floor(i / TILES_X)
        const tile = this.tileCache[this.MM.getUint8(FOREGROUND_OFFSET + i)]
        this.renderer.drawGridAlignedTile(x, y, tile)
      }

      // Signal the CPU to handle an interrupt
      this.cpu.handleInterrupt(1)
    }

    for (let i = 0; i < CYCLES_PER_ANIMATION_FRAME; i++) {
      this.cpu.step()
    }

    requestAnimationFrame(this.draw.bind(this))
  }
}

new Game('./frogger/main.asb')
