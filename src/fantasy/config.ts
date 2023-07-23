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
