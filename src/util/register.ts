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
  MB: 12,
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
