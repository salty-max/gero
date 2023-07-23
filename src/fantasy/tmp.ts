import { colours } from './colours'

// const TILE_WIDTH = 30
// const TILE_HEIGHT = 14
const TILE_WIDTH = 16
const TILE_HEIGHT = 16
const PIXELS_PER_TILE = 8
const SCALE_FACTOR = 6

const w = TILE_WIDTH * PIXELS_PER_TILE * SCALE_FACTOR
const h = TILE_HEIGHT * PIXELS_PER_TILE * SCALE_FACTOR

const canvas = document.getElementById('screen') as HTMLCanvasElement
canvas.width = w
canvas.height = h

const ctx = canvas.getContext('2d')
if (!ctx) throw new Error('Could not get 2D context')

class Screen {
  private _ctx: CanvasRenderingContext2D

  constructor(canvas: HTMLCanvasElement) {
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new Error('Could not get 2D context')
    this._ctx = ctx
  }

  get ctx() {
    return this._ctx
  }

  fill([r, g, b, a]: number[]) {
    this.ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${a})`
  }

  drawPixel(x: number, y: number, c: number[]) {
    this.fill.call(this, c)
    this.ctx.fillRect(
      x * SCALE_FACTOR,
      y * SCALE_FACTOR,
      SCALE_FACTOR,
      SCALE_FACTOR
    )
  }

  drawTile(x: number, y: number, tileData: number[]) {
    // Iterate over each line of the tile (8 lines for an 8x8 tile)
    for (let oy = 0; oy < 8; oy++) {
      // Iterate over each pixel pair in the line. Each byte represents two pixels, hence 'ox' is incremented by 2
      for (let ox = 0; ox < 8; ox += 2) {
        // Get the byte index for the tile data.
        // (oy * PIXELS_PER_TILE + ox) calculates the linear index of the current pixel pair in the tile
        // Dividing by 2 because each byte in the tile data represents two pixels
        const index = (oy * PIXELS_PER_TILE + ox) / 2

        // Fetch the byte representing the current pixel pair from the tile data
        const byte = tileData[index]

        // The color indices are extracted from the byte.
        // byte >> 4 shifts the bits of the byte four places to the right effectively isolating the high nibble (first pixel color index)
        // byte & 0xf performs a bitwise AND operation with 0xf (1111 in binary) to isolate the low nibble (second pixel color index)
        const c1 = colours[byte >> 4]
        const c2 = colours[byte & 0xf]

        // The two pixels are drawn to the screen at the appropriate positions
        this.drawPixel(x + ox, y + oy, c1)
        this.drawPixel(x + ox + 1, y + oy, c2)
      }
    }
  }
}

// for (let y = 0; y < TILE_HEIGHT * PIXELS_PER_TILE; y++) {
//   for (let x = 0; x < TILE_WIDTH * PIXELS_PER_TILE; x++) {
//     const index = (x / y ** 0.5) & 0xf
//     console.log(index)
//     drawPixel(x, y, colours[index])
//   }
// }

class Tile {
  canvas: HTMLCanvasElement
  ctx: CanvasRenderingContext2D | null
  screen: Screen

  constructor(rootCtx: Screen, data: number[]) {
    this.screen = rootCtx
    this.canvas = document.createElement('canvas')
    this.ctx = this.canvas.getContext('2d')
    this.canvas.width = PIXELS_PER_TILE * SCALE_FACTOR
    this.canvas.height = PIXELS_PER_TILE * SCALE_FACTOR

    this.screen.drawTile(0, 0, data)
  }
}

class Renderer {
  private screen: Screen

  constructor(screen: Screen) {
    this.screen = screen
  }

  drawGridAlignedTile(x: number, y: number, tile: Tile) {
    this.screen.ctx.drawImage(
      tile.canvas,
      x * PIXELS_PER_TILE * SCALE_FACTOR,
      y * PIXELS_PER_TILE * SCALE_FACTOR
    )
  }

  drawPixelAlignedTile(x: number, y: number, tile: Tile) {
    this.screen.ctx.drawImage(tile.canvas, x * SCALE_FACTOR, y * SCALE_FACTOR)
  }

  clear() {
    this.screen.fill(colours[0])
    this.screen.ctx.fillRect(0, 0, w, h)
  }
}

const screen = new Screen(canvas)

// This is an array of 8-bit values representing pixel colors in a tile.
// Each byte represents two pixels, with the high nibble (4 bits) representing one pixel and the low nibble representing the next pixel.
/* prettier-ignore */
const movingTile = new Tile(screen, [
  0x00, 0x11, 0x22, 0x33,
  0x00, 0x11, 0x22, 0x33,
  0x44, 0x55, 0x66, 0x77,
  0x44, 0x55, 0x66, 0x77,
  0x88, 0x99, 0xaa, 0xbb,
  0x88, 0x99, 0xaa, 0xbb,
  0xcc, 0xdd, 0xee, 0xff,
  0xcc, 0xdd, 0xee, 0xff,
])

const blackTile = new Tile(
  screen,
  Array.from({ length: 32 }, () => 0xff)
)
const blueTile = new Tile(
  screen,
  Array.from({ length: 32 }, () => 0x33)
)

const renderer = new Renderer(screen)

const pos = { x: 0, y: 0 }

const draw = () => {
  renderer.clear()

  for (let y = 0; y < TILE_HEIGHT; y++) {
    for (let x = 0; x < TILE_WIDTH; x++) {
      if ((x + y) % 2 === 0) {
        renderer.drawGridAlignedTile(x, y, blackTile)
      } else {
        renderer.drawGridAlignedTile(x, y, blueTile)
      }
    }
  }

  pos.x = (pos.x + 1) % (TILE_WIDTH * PIXELS_PER_TILE)
  pos.y = (pos.y + 1) % (TILE_HEIGHT * PIXELS_PER_TILE)
  renderer.drawPixelAlignedTile(pos.x, pos.y, movingTile)

  requestAnimationFrame(draw)
}

draw()
