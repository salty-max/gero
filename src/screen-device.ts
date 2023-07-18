import { Device } from "./memory-mapper"

/**
 * @interface ScreenDevice
 * @extends Device
 */
interface ScreenDevice extends Device {}

/**
 * Erases the screen in the terminal.
 */
const eraseScreen = () => {
  process.stdout.write(`\x1b[2J`)
}

/**
 * Set text to bold.
 */
const setBold = () => {
  process.stdout.write(`\x1b[1m`)
}

/**
 * Set regular.
 */
const setRegular = () => {
  process.stdout.write(`\x1b[0m`)
}

/**
 * Set text to black.
 */
const setTextBlack = () => {
  process.stdout.write(`\x1b[30m`)
}

/**
 * Set text to red.
 */
const setTextRed = () => {
  process.stdout.write(`\x1b[31m`)
}

/**
 * Set text to green.
 */
const setTextGreen = () => {
  process.stdout.write(`\x1b[32m`)
}

/**
 * Set text to yellow.
 */
const setTextYellow = () => {
  process.stdout.write(`\x1b[33m`)
}

/**
 * Set text to blue.
 */
const setTextBlue = () => {
  process.stdout.write(`\x1b[34m`)
}

/**
 * Set text to magenta.
 */
const setTextMagenta = () => {
  process.stdout.write(`\x1b[35m`)
}

/**
 * Set text to cyan.
 */
const setTextCyan = () => {
  process.stdout.write(`\x1b[36m`)
}

/**
 * Moves the cursor to the given (x,y) position in the terminal.
 * @param {number} x - The horizontal coordinate to move to
 * @param {number} y - The vertical coordinate to move to
 */
const moveTo = (x: number, y: number) => {
  process.stdout.write(`\x1b[${y};${x}H`)
}

/**
 * Creates a ScreenDevice that represents the screen of the terminal.
 * @returns {ScreenDevice} A ScreenDevice that can write to the screen
 */
export const createScreenDevice = (): ScreenDevice => {
  return {
    getUint8: () => 0,
    getUint16: () => 0,
    setUint8: () => {},
    setUint16: (address: number, data: number) => {
      // Extract the command to apply from the data
      const command = (data & 0xff00) >> 8

      // Extract the ASCII value of the character from the data
      const characterValue = data & 0x00ff

      // Apply escape code depending on the given command
      switch (command) {
        case 0xff:
          eraseScreen()
          break
        case 0x01:
          setBold()
          break
        case 0x30:
          setTextBlack()
          break
        case 0x31:
          setTextRed()
          break
        case 0x32:
          setTextGreen()
          break
        case 0x33:
          setTextYellow()
          break
        case 0x34:
          setTextBlue()
          break
        case 0x35:
          setTextMagenta()
          break
        case 0x36:
          setTextCyan()
          break
        default:
          setRegular()
          break
      }

      // Calculate the x and y position of the character on the screen
      // Each character cell is two characters wide because each cell
      // represents a memory address, and the terminal has 16 cells per row
      const x = (address % 16) + 1
      const y = Math.floor(address / 16) + 1

      // Move the cursor to the calculated position
      moveTo(x * 2, y)

      // Convert the ASCII value to a string and write it to the terminal
      const character = String.fromCharCode(characterValue)
      process.stdout.write(character)
    },
  }
}
