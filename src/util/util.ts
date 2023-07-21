export const ANSI_COLOR_RED = '\x1b[31m'
export const ANSI_COLOR_GREEN = '\x1b[32m'
export const ANSI_COLOR_BLUE = '\x1b[34m'
export const ANSI_COLOR_BOLD = '\x1b[1m'
export const ANSI_COLOR_RESET = '\x1b[0m'

export enum Register {
  IP,
  ACC,
  R1,
  R2,
  R3,
  R4,
  R5,
  R6,
  R7,
  R8,
  SP,
  FP,
}

export const GENERIC_REGISTERS_COUNT = 8

export const REGISTER_NAMES = [
  'ip', // Instruction pointer
  'acc', // Accumulator
  ...Array.from({ length: GENERIC_REGISTERS_COUNT }, (_, i) => `r${i + 1}`), // Generic-purpose registers
  'sp', // Stack pointer
  'fp', // Stack frame pointer
]