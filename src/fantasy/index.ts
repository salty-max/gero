// Import colours from external module
import { colours } from './colours'

// Define constant values for tile size, pixel density and scaling
const TILE_WIDTH = 30
const TILE_HEIGHT = Math.round((9 / 16) * TILE_WIDTH)
const PIXELS_PER_TILE = 8
const SCALE_FACTOR = 6

// Compute the width and height of the canvas
const w = TILE_WIDTH * PIXELS_PER_TILE * SCALE_FACTOR
const h = TILE_HEIGHT * PIXELS_PER_TILE * SCALE_FACTOR

// Grab the canvas element from the DOM and set its width and height
const canvas = document.getElementById('screen') as HTMLCanvasElement
canvas.width = w
canvas.height = h

// Display class handles drawing on a specific canvas
class Display {
  private ctx: CanvasRenderingContext2D // 2D rendering context of the canvas

  constructor(canvas: HTMLCanvasElement) {
    // Grab 2D context of the canvas
    const ctx = canvas.getContext('2d')
    // If we can't get the context, throw an error
    if (!ctx) throw new Error('Could not get 2D context')
    // If we got the context, store it in this object
    this.ctx = ctx
  }

  // Set the fill colour for the context
  fill = ([r, g, b, a]: number[]): void => {
    this.ctx.fillStyle = `rgba(${r},${g},${b},${a})`
  }

  // Draw a pixel on the context
  drawPixel = (x: number, y: number, c: number[]): void => {
    this.fill(c) // Set fill colour
    // Draw the rectangle (which is a pixel here due to scale)
    this.ctx.fillRect(
      x * SCALE_FACTOR,
      y * SCALE_FACTOR,
      SCALE_FACTOR,
      SCALE_FACTOR
    )
  }

  // Draw a tile on the context
  drawTile = (x: number, y: number, tileData: number[]): void => {
    // Iterate through each pixel in the tile
    for (let oy = 0; oy < 8; oy++) {
      for (let ox = 0; ox < 8; ox += 2) {
        // Calculate the index for the colour data
        const index = (oy * PIXELS_PER_TILE + ox) / 2
        const byte = tileData[index]

        // Extract the two colours for each pixel in the byte
        const c1 = colours[byte >> 4]
        const c2 = colours[byte & 0xf]

        // Draw each pixel on the context
        this.drawPixel(x + ox, y + oy, c1)
        this.drawPixel(x + ox + 1, y + oy, c2)
      }
    }
  }
}

// Create a new Display object for the main screen
const screen = new Display(canvas)

// Tile class represents a tile, which is essentially a mini canvas
class Tile {
  canvas: HTMLCanvasElement

  constructor(data: number[]) {
    // Create a new canvas for this tile
    this.canvas = document.createElement('canvas')
    this.canvas.width = PIXELS_PER_TILE * SCALE_FACTOR
    this.canvas.height = PIXELS_PER_TILE * SCALE_FACTOR
    const display = new Display(this.canvas)

    // Draw the tile data onto the canvas
    display.drawTile(0, 0, data)
  }
}

// Renderer class takes care of drawing tiles onto the main screen
class Renderer {
  ctx: CanvasRenderingContext2D // 2D rendering context of the canvas

  constructor(canvas: HTMLCanvasElement) {
    // Grab the 2D context
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new Error('Could not get 2D context')
    this.ctx = ctx
  }

  // Draw a tile onto the main screen at a grid aligned position
  drawGridAlignedTile(x: number, y: number, tile: Tile) {
    this.ctx.drawImage(
      tile.canvas,
      x * PIXELS_PER_TILE * SCALE_FACTOR,
      y * PIXELS_PER_TILE * SCALE_FACTOR
    )
  }

  // Draw a tile onto the main screen at a pixel aligned position
  drawPixelAlignedTile(x: number, y: number, tile: Tile) {
    this.ctx.drawImage(tile.canvas, x * SCALE_FACTOR, y * SCALE_FACTOR)
  }

  // Clear the main screen
  clear() {
    // Fill the screen with the first colour
    screen.fill(colours[0])
    // Draw a rectangle covering the entire canvas
    this.ctx.fillRect(0, 0, w, h)
  }
}

// Create different tiles using different colours
/* prettier-ignore */
const movingTile = new Tile([
  0x00, 0x11, 0x22, 0x33,
  0x00, 0x11, 0x22, 0x33,
  0x44, 0x55, 0x66, 0x77,
  0x44, 0x55, 0x66, 0x77,
  0x88, 0x99, 0xaa, 0xbb,
  0x88, 0x99, 0xaa, 0xbb,
  0xcc, 0xdd, 0xee, 0xff,
  0xcc, 0xdd, 0xee, 0xff,
])
const blackTile = new Tile(Array.from({ length: 32 }, () => 0xff))
const blueTile = new Tile(Array.from({ length: 32 }, () => 0x33))

// Create a new Renderer for the main screen
const renderer = new Renderer(canvas)

// Start position for the moving tile
const pos = { x: 0, y: 0 }

// The main draw loop
const draw = () => {
  // Clear the screen
  renderer.clear()

  // Draw the grid of black and blue tiles
  for (let y = 0; y < TILE_HEIGHT; y++) {
    for (let x = 0; x < TILE_WIDTH; x++) {
      if ((x + y) % 2 === 0) {
        renderer.drawGridAlignedTile(x, y, blackTile)
      } else {
        renderer.drawGridAlignedTile(x, y, blueTile)
      }
    }
  }

  // Update position for moving tile and draw it
  pos.x = (pos.x + 1) % (TILE_WIDTH * PIXELS_PER_TILE)
  pos.y = (pos.y + 1) % (TILE_HEIGHT * PIXELS_PER_TILE)
  renderer.drawPixelAlignedTile(pos.x, pos.y, movingTile)

  // Request the next animation frame
  requestAnimationFrame(draw)
}

// Start the draw loop
draw()
