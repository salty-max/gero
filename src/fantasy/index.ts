import { assembleString } from '../assembler'
import { CPU, MemoryMapper, createRAM, createROM } from '../vm'
import { SCREEN_H, SCREEN_W, SPRITE_SIZE, TILE_SIZE } from './config'
import { Display, Renderer, Tile } from './graphics'

// Define memory sizes for the different sections of the game memory
// TILE_MEMORY_SIZE corresponds to the space in memory allocated for the game tiles.
const TILE_MEMORY_SIZE = 0x2000 // (8192 bytes)
// RAM1_SIZE is used for the interrupt vector, sprites, background, and foreground
const RAM1_SIZE = 0x20 + 0x200 + 0x200 + 0x200 // 0x0620 (1538 bytes)
// INPUT_SIZE represents the memory size allocated for game inputs
const INPUT_SIZE = 0x8 // (8 bytes)
// RAM2_SIZE is for global settings, game code and data, and the stack
const RAM2_SIZE = 0x10000 - TILE_MEMORY_SIZE - RAM1_SIZE - INPUT_SIZE // 0xd9d8 (55768 bytes)

// Create the memory for different components of the game
const tileMemory = createROM(TILE_MEMORY_SIZE)
const RAMSegment1 = createRAM(RAM1_SIZE)
const inputMemory = createROM(INPUT_SIZE)
const RAMSegment2 = createRAM(RAM2_SIZE)

// Create a new memory mapper and map the different sections of memory to it
const MM = new MemoryMapper()
MM.map(tileMemory, 0x0000, TILE_MEMORY_SIZE)
MM.map(RAMSegment1, 0x2000, RAM1_SIZE)
MM.map(inputMemory, 0x2620, INPUT_SIZE)
MM.map(RAMSegment2, 0x2628, RAM2_SIZE)

// fullColourTile is a function that creates an array of length 32, where each element is a bitwise operation
// involving the provided colour (i.e., shifting it left by 4 bits and combining it with the original colour).
const fullColourTile = (colour: number) =>
  Array.from({ length: TILE_SIZE }, () => (colour << 4) | colour)

// fullColourTiles is an array that stores the full colour tile for each of the 16 possible colours.
const fullColourTiles = []
for (let i = 0; i < 16; i++) {
  fullColourTiles.push(...fullColourTile(i))
}

// Load fullColourTiles into the tile memory.
tileMemory.load(fullColourTiles)

// Define offsets for background and foreground in memory.
const BACKGROUND_OFFSET = 0x2220
const FOREGROUND_OFFSET = 0x2420

// Define the number of tiles along the x and y axes.
const TILES_X = 32
const TILES_Y = 16

// Loop over each tile in the grid and set its colour based on its position.
// This creates a pattern in the grid.
for (let i = 0; i < TILES_X * TILES_Y; i++) {
  const x = i % TILES_X
  const y = Math.floor(i / TILES_X)

  if ((x + y) % 2 === 0) {
    MM.setUint8(BACKGROUND_OFFSET + i, 0xf)
  } else if ((x + y) % 3 === 0) {
    MM.setUint8(BACKGROUND_OFFSET + i, 0xa)
  } else {
    MM.setUint8(BACKGROUND_OFFSET + i, 0x4)
  }
}

// Define the offset for the sprite table in memory.
const SPRITE_TABLE_OFFSET = 0x2020

// Populate the sprite table in memory with initial values.
// Each sprite entry requires 16 bytes, of which only a part is set here.
MM.setUint16(SPRITE_TABLE_OFFSET + 0, 0) // x-coordinate of sprite 0
MM.setUint16(SPRITE_TABLE_OFFSET + 2, 32) // y-coordinate of sprite 0
MM.setUint16(SPRITE_TABLE_OFFSET + 4, 6) // tile index of sprite 0

MM.setUint16(16 + SPRITE_TABLE_OFFSET + 0, 64) // x-coordinate of sprite 1
MM.setUint16(16 + SPRITE_TABLE_OFFSET + 2, 20) // y-coordinate of sprite 1
MM.setUint16(16 + SPRITE_TABLE_OFFSET + 4, 2) // tile index of sprite 1

/* prettier-ignore */
const inputStates = [
  0 /* UP */,
  0 /* DOWN */,
  0 /* LEFT */,
  0 /* RIGHT */,
  0 /* A */,
  0 /* B */,
  0 /* START */,
  0 /* SELECT */,
]

// Define a listener for keydown events. Depending on the key pressed, the corresponding input state is updated.
// Each inputState corresponds to a different keypress action.
document.addEventListener('keydown', (e) => {
  switch (e.key) {
    case 'ArrowUp':
      inputStates[0] = 1 // UP
      return
    case 'ArrowDown':
      inputStates[1] = 1 // DOWN
      return
    case 'ArrowLeft':
      inputStates[2] = 1 // LEFT
      return
    case 'ArrowRight':
      inputStates[3] = 1 // RIGHT
      return
    case 'z':
      inputStates[4] = 1 // A
      return
    case 'x':
      inputStates[5] = 1 // B
      return
    case 'Enter':
      inputStates[6] = 1 // START
      return
    case 'Shift':
      inputStates[7] = 1 // SELECT
      return
  }
})

// Create a cache for game tiles in memory
const tileCache: Tile[] = []
for (let i = 0; i < TILE_MEMORY_SIZE; i += TILE_SIZE) {
  tileCache.push(new Tile(tileMemory.slice(i, i + TILE_SIZE)))
}

// Define the start of the game code in memory
const CODE_OFFSET = 0x2668

// Use the assembly string to generate machine code and symbols for the game
const { machineCode, symbols } = assembleString(
  `
start:

wait:
  mov [!wait], ip

after_frame:
  rti
`.trim(),
  CODE_OFFSET
)

// Load the machine code into memory at the specified offset
machineCode.forEach((byte: number, i: number) =>
  MM.setUint8(CODE_OFFSET + i, byte)
)

// Define the offset in memory for interrupt vector
const INTERRUPT_VECTOR_OFFSET = 0x2000

// Set the start of the game code and the end of a frame in the interrupt vector
MM.setUint16(INTERRUPT_VECTOR_OFFSET, CODE_OFFSET)
MM.setUint16(INTERRUPT_VECTOR_OFFSET + 2, symbols.after_frame)

// Create a new CPU and point it to the interrupt vector in memory
const cpu = new CPU(MM, INTERRUPT_VECTOR_OFFSET)

// Set the target frames per second and the time allowed for each frame
const FPS_TARGET = 30
const TIME_PER_FRAME_MS = 1000 / FPS_TARGET
// Define the number of CPU cycles to execute per animation frame
const CYCLES_PER_ANIMATION_FRAME = 200

// Create a new renderer for the game and attach it to the 'screen' canvas element
const canvas = document.getElementById('screen') as HTMLCanvasElement
canvas.width = SCREEN_W
canvas.height = SCREEN_H
const screen = new Display(canvas)
const r = new Renderer(screen)
let last = Date.now()

const drawCallback = () => {
  const now = Date.now() // Get the current time
  const diff = now - last // Calculate the time elapsed since the last frame

  // If enough time has passed to render a new frame
  if (diff > TIME_PER_FRAME_MS) {
    last = now // Update the timestamp of the last frame
    inputMemory.load(inputStates) // Load the current state of the input into the input memory

    // Reset the state of the input
    for (let i = 0; i < inputStates.length; i++) {
      inputStates[i] = 0
    }

    // Render the background tiles
    for (let i = 0; i < TILES_X * TILES_Y; i++) {
      const x = i % TILES_X
      const y = Math.floor(i / TILES_X)
      const tile = tileCache[MM.getUint8(BACKGROUND_OFFSET + i)]
      r.drawGridAlignedTile(x, y, tile)
    }

    // Render the sprites
    for (let i = 0; i < 32; i++) {
      const spriteBase = SPRITE_TABLE_OFFSET + i * SPRITE_SIZE
      const x = MM.getUint8(spriteBase + 0)
      const y = MM.getUint8(spriteBase + 2)
      const tile = MM.getUint8(spriteBase + 4) + MM.getUint8(spriteBase + 5)
      r.drawPixelAlignedTile(x, y, tileCache[tile])
    }

    // Render the foreground tiles
    for (let i = 0; i < TILES_X * TILES_Y; i++) {
      const x = i % TILES_X
      const y = Math.floor(i / TILES_X)
      const tile = tileCache[MM.getUint8(FOREGROUND_OFFSET + i)]
      r.drawGridAlignedTile(x, y, tile)
    }

    // Signal the CPU to handle an interrupt
    cpu.handleInterrupt(1)
  }

  // Step the CPU for a certain number of cycles
  for (let i = 0; i < CYCLES_PER_ANIMATION_FRAME; i++) {
    cpu.step()
  }

  // Request the browser to call this function again when it's time to update the next frame
  requestAnimationFrame(drawCallback)
}

// Start the main game loop
drawCallback()
