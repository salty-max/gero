import { Colour, colours } from './colours'
import {
  PIXELS_PER_TILE,
  SCALE_FACTOR,
  TILE_HEIGHT,
  TILE_WIDTH,
} from './config'

const w = TILE_WIDTH * PIXELS_PER_TILE * SCALE_FACTOR
const h = TILE_HEIGHT * PIXELS_PER_TILE * SCALE_FACTOR

const canvas = <HTMLCanvasElement>document.getElementById('screen')
canvas.width = w
canvas.height = h

export class Tile {
  private canvas: HTMLCanvasElement
  private ctx: CanvasRenderingContext2D

  constructor(private tileData: Uint8Array) {
    this.canvas = document.createElement('canvas')
    this.ctx = this.canvas.getContext('2d')!
    this.canvas.width = PIXELS_PER_TILE * SCALE_FACTOR
    this.canvas.height = PIXELS_PER_TILE * SCALE_FACTOR

    this.drawTile(0, 0, tileData)
  }

  private setFill([r, g, b, a]: Colour) {
    this.ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${a})`
  }

  private drawPixel(x: number, y: number, c: Colour) {
    this.setFill(c)
    this.ctx.fillRect(
      x * SCALE_FACTOR,
      y * SCALE_FACTOR,
      SCALE_FACTOR,
      SCALE_FACTOR
    )
  }

  private drawTile(x: number, y: number, tileData: Uint8Array) {
    for (let oy = 0; oy < PIXELS_PER_TILE; oy++) {
      for (let ox = 0; ox < PIXELS_PER_TILE; ox += 2) {
        const index = (oy * PIXELS_PER_TILE + ox) / 2
        const byte = tileData[index]

        const c1 = colours[byte >> 4]
        const c2 = colours[byte & 0xf]

        this.drawPixel(x + ox, y + oy, c1)
        this.drawPixel(x + ox + 1, y + oy, c2)
      }
    }
  }

  get TileCanvas() {
    return this.canvas
  }
}

export class Renderer {
  private ctx: CanvasRenderingContext2D

  constructor() {
    this.ctx = canvas.getContext('2d')!
  }

  private setFill([r, g, b, a]: Colour) {
    this.ctx.fillStyle = `rgba(${r}, ${g}, ${b}, ${a})`
  }

  drawGridAlignedTile(tileX: number, tileY: number, tile: Tile) {
    this.ctx.drawImage(
      tile.TileCanvas,
      tileX * PIXELS_PER_TILE * SCALE_FACTOR,
      tileY * PIXELS_PER_TILE * SCALE_FACTOR
    )
  }

  drawPixelAlignedTile(x: number, y: number, tile: Tile) {
    this.ctx.drawImage(tile.TileCanvas, x * SCALE_FACTOR, y * SCALE_FACTOR)
  }

  clear() {
    this.setFill([colours[0][0], colours[0][1], colours[0][2], 1])
    this.ctx.fillRect(0, 0, w, h)
  }
}
