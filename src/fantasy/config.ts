// Define constant values for tile size, pixel density and scaling
export const TILE_WIDTH = 30
//const TILE_HEIGHT = Math.round((9 / 16) * TILE_WIDTH)
export const TILE_HEIGHT = 14
export const PIXELS_PER_TILE = 8
export const SCALE_FACTOR = 6

// Compute the width and height of the canvas
export const SCREEN_W = TILE_WIDTH * PIXELS_PER_TILE * SCALE_FACTOR
export const SCREEN_H = TILE_HEIGHT * PIXELS_PER_TILE * SCALE_FACTOR

// Define the size of a tile in bytes
export const TILE_SIZE = 32
// Define the size of a sprite in bytes
export const SPRITE_SIZE = 16
// Define the maximum number of sprites
export const MAX_SPRITES = 32
// Define the number of tiles along the x and y axes.
export const TILES_X = 32
export const TILES_Y = 16

// Define memory sizes for the different sections of the game memory
// TILE_MEMORY_SIZE corresponds to the space in memory allocated for the game tiles.
export const TILE_MEMORY_SIZE = 0x2000 // (8192 bytes)
// RAM1_SIZE is used for the interrupt vector, sprites, background, and foreground
export const RAM1_SIZE = 0x20 + 0x200 + 0x200 + 0x200 // 0x0620 (1538 bytes)
// INPUT_SIZE represents the memory size allocated for game inputs
export const INPUT_SIZE = 0x8 // (8 bytes)
// RAM2_SIZE is for global settings, game code and data, and the stack
export const RAM2_SIZE = 0x10000 - TILE_MEMORY_SIZE - RAM1_SIZE - INPUT_SIZE // 0xd9d8 (55768 bytes)

// Set the target frames per second and the time allowed for each frame
export const FPS_TARGET = 30
export const TIME_PER_FRAME_MS = 1000 / FPS_TARGET
// Define the number of CPU cycles to execute per animation frame
export const CYCLES_PER_ANIMATION_FRAME = 200

// Define offsets for background and foreground in memory.
export const BACKGROUND_OFFSET = 0x2220
export const FOREGROUND_OFFSET = 0x2420
// Define the offset for the sprite table in memory.
export const SPRITE_TABLE_OFFSET = 0x2020
// Define the offset for the input memory in memory.
export const INPUT_OFFSET = 0x2620
// Define the start of the game code in memory
export const CODE_OFFSET = 0x2668
// Define the offset in memory for interrupt vector
export const INTERRUPT_VECTOR_OFFSET = 0x2000
