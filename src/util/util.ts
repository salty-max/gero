export const ANSI_COLOR_RED = '\x1b[31m'
export const ANSI_COLOR_GREEN = '\x1b[32m'
export const ANSI_COLOR_BLUE = '\x1b[34m'
export const ANSI_COLOR_BOLD = '\x1b[1m'
export const ANSI_COLOR_RESET = '\x1b[0m'

export const Register: Record<string, number> = {
  IP: 0,
  ACC: 1,
  R1: 2,
  R2: 3,
  R3: 4,
  R4: 5,
  R5: 6,
  R6: 7,
  R7: 8,
  R8: 9,
  SP: 10,
  FP: 11,
}

export type MappedRegister = {
  [key in keyof typeof Register]: number
}

export const GENERIC_REGISTERS_COUNT = 8

export const REGISTER_NAMES = [
  'ip', // Instruction pointer
  'acc', // Accumulator
  ...Array.from({ length: GENERIC_REGISTERS_COUNT }, (_, i) => `r${i + 1}`), // Generic-purpose registers
  'sp', // Stack pointer
  'fp', // Stack frame pointer
]
