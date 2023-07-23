// Import colours from external module
import { colours } from './colours'
import { PIXELS_PER_TILE, SCALE_FACTOR, SCREEN_H, SCREEN_W } from './config'

// Display class handles drawing on a specific canvas
export class Display {
  private _ctx: CanvasRenderingContext2D // 2D rendering context of the canvas

  constructor(canvas: HTMLCanvasElement) {
    // Grab 2D context of the canvas
    const ctx = canvas.getContext('2d')
    // If we can't get the context, throw an error
    if (!ctx) throw new Error('Could not get 2D context')
    // If we got the context, store it in this object
    this._ctx = ctx
  }

  get ctx(): CanvasRenderingContext2D {
    return this._ctx
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
  drawTile = (x: number, y: number, tileData: Uint8Array): void => {
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

// Tile class represents a tile, which is essentially a mini canvas
export class Tile {
  canvas: HTMLCanvasElement

  constructor(data: Uint8Array) {
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
export class Renderer {
  display: Display

  constructor(display: Display) {
    this.display = display
  }

  // Draw a tile onto the main screen at a grid aligned position
  drawGridAlignedTile(x: number, y: number, tile: Tile) {
    this.display.ctx.drawImage(
      tile.canvas,
      x * PIXELS_PER_TILE * SCALE_FACTOR,
      y * PIXELS_PER_TILE * SCALE_FACTOR
    )
  }

  // Draw a tile onto the main screen at a pixel aligned position
  drawPixelAlignedTile(x: number, y: number, tile: Tile) {
    this.display.ctx.drawImage(tile.canvas, x * SCALE_FACTOR, y * SCALE_FACTOR)
  }

  // Clear the main screen
  clear() {
    // Fill the screen with the first colour
    this.display.fill(colours[0])
    // Draw a rectangle covering the entire canvas
    this.display.ctx.fillRect(0, 0, SCREEN_W, SCREEN_H)
  }
}
