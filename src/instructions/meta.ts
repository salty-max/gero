/**
 * @file meta.ts
 *
 * This file declares constants for various instruction codes used in the assembly language.
 * Each constant is associated with a specific byte code which represents a unique instruction.
 * The relations between the labels OR the byte codes are as follows:
 *
 * Move instructions
 * - MOV_LIT_REG:       0x10, Move Literal to Register
 * - MOV_REG_REG:       0x11, Move Register to Register
 * - MOV_REG_MEM:       0x12, Move Register to Memory
 * - MOV_MEM_REG:       0x13, Move Memory to Register
 * - MOV_LIT_MEM:       0x14, Move Literal to Memory
 * - MOV_REG_PTR_REG:   0x15, Move Register* to Register
 * - MOV_LIT_OFF_REG:   0x16, Move Value at [Literal + Register] to Register
 * Arithmetic instructions
 * - ADD_LIT_REG:       0x1B, Add Literal to Register
 * - ADD_REG_REG:       0x1C, Add Register to Register
 * - SUB_LIT_REG:       0x1D, Subtract Literal from Register
 * - SUB_REG_LIT:       0x1E, Subtract Register from Literal
 * - SUB_REG_REG:       0x1F, Subtract Register from Register
 * - MUL_LIT_REG:       0x20, Multiply Literal with Register
 * - MUL_REG_REG:       0x21, Multiply Register with Register
 * - INC_REG:           0x35, Increment Register
 * - DEC_REG:           0x36, Decrement Register
 * Logical instructions
 * - LSF_REG_LIT:       0x26, Left shift Register by Literal
 * - LSF_REG_REG:       0x27, Left shift Register by Register
 * - RSF_REG_LIT:       0x2A, Right shift Register by Literal
 * - RSF_REG_REG:       0x2B, Right shift Register by Register
 * - AND_REG_LIT:       0x2E, And Register by Literal
 * - AND_REG_REG:       0x2F, And Register by Register
 * - OR_REG_LIT:        0x30, Or Register by Literal
 * - OR_REG_REG:        0x31, Or Register by Register
 * - XOR_REG_LIT:       0x32, Xor Register by Literal
 * - XOR_REG_REG:       0x33, Xor Register by Register
 * - NOT:               0x34, Not
 * Branching instructions
 * - JEQ_REG:           0x3E, Jump if Equal (Register)
 * - JEQ_LIT:           0x3F, Jump if Equal (Literal)
 * - JNE_REG:           0x40, Jump if Not Equal (Register)
 * - JNE_LIT:           0x41, Jump if Not Equal (Literal)
 * - JLT_REG:           0x42, Jump if Lesser Than (Register)
 * - JLT_LIT:           0x43, Jump if Lesser Than (Literal)
 * - JGT_REG:           0x44, Jump if Greater Than (Register)
 * - JGT_LIT:           0x45, Jump if Greater Than (Literal)
 * - JLE_REG:           0x46, Jump if Lesser Than Or Equal (Register)
 * - JLE_LIT:           0x47, Jump if Lesser Than Or Equal (Literal)
 * - JGE_REG:           0x48, Jump if Greater Than Or Equal (Register)
 * - JGE_LIT:           0x49, Jump if Greater Than  Or Equal(Literal)
 * Stack instructions
 * - PSH_LIT:           0x17, Push Literal
 * - PSH_REG:           0x18, Push Register
 * - POP:               0x1A, Pop to Register
 * Subroutines instructions
 * - CAL_LIT:           0x5E, Call Literal
 * - CAL_REG:           0x5F, Call Register
 * - RET:               0x60, Return
 * System instructions
 * - HLT:               0xFF, Halt
 *
 * Each byte code is represented in hexadecimal format.
 */

export enum InstructionType {
  LIT_REG,
  REG_LIT,
  REG_LIT_8,
  REG_REG,
  REG_MEM,
  MEM_REG,
  LIT_MEM,
  REG_PTR_REG,
  LIT_OFF_REG,
  NO_ARGS,
  SINGLE_REG,
  SINGLE_LIT,
}

const instructionSizes: Record<string, number> = {
  LIT_REG: 4,
  REG_LIT: 4,
  REG_LIT_8: 3,
  REG_REG: 3,
  REG_MEM: 4,
  MEM_REG: 5,
  LIT_MEM: 5,
  REG_PTR_REG: 3,
  LIT_OFF_REG: 5,
  NO_ARGS: 1,
  SINGLE_REG: 2,
  SINGLT_LIT: 3,
}

export interface IMeta {
  instruction: string
  opcode: number
  type: InstructionType
  size: number
  mnemonic: string
}

export const meta: Array<IMeta> = [
  {
    instruction: 'MOV_LIT_REG',
    opcode: 0x10,
    type: InstructionType.LIT_REG,
    size: instructionSizes.LIT_REG,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_REG',
    opcode: 0x11,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_MEM',
    opcode: 0x12,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_MEM_REG',
    opcode: 0x13,
    type: InstructionType.MEM_REG,
    size: instructionSizes.MEM_REG,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_LIT_MEM',
    opcode: 0x14,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_PTR_REG',
    opcode: 0x15,
    type: InstructionType.REG_PTR_REG,
    size: instructionSizes.REG_PTR_REG,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_LIT_OFF_REG',
    opcode: 0x16,
    type: InstructionType.LIT_OFF_REG,
    size: instructionSizes.LIT_OFF_REG,
    mnemonic: 'mov',
  },
  {
    instruction: 'ADD_LIT_REG',
    opcode: 0x1b,
    type: InstructionType.LIT_REG,
    size: instructionSizes.LIT_REG,
    mnemonic: 'add',
  },
  {
    instruction: 'ADD_REG_REG',
    opcode: 0x1c,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'add',
  },
  {
    instruction: 'SUB_LIT_REG',
    opcode: 0x1d,
    type: InstructionType.LIT_REG,
    size: instructionSizes.LIT_REG,
    mnemonic: 'sub',
  },
  {
    instruction: 'SUB_REG_LIT',
    opcode: 0x1e,
    type: InstructionType.REG_LIT,
    size: instructionSizes.REG_LIT,
    mnemonic: 'sub',
  },
  {
    instruction: 'SUB_REG_REG',
    opcode: 0x1f,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'sub',
  },
  {
    instruction: 'MUL_LIT_REG',
    opcode: 0x20,
    type: InstructionType.LIT_REG,
    size: instructionSizes.LIT_REG,
    mnemonic: 'mul',
  },
  {
    instruction: 'MUL_REG_REG',
    opcode: 0x21,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'mul',
  },
  {
    instruction: 'INC_REG',
    opcode: 0x35,
    type: InstructionType.SINGLE_REG,
    size: instructionSizes.SINGLE_REG,
    mnemonic: 'inc',
  },
  {
    instruction: 'DEC_REG',
    opcode: 0x36,
    type: InstructionType.SINGLE_REG,
    size: instructionSizes.SINGLE_REG,
    mnemonic: 'dec',
  },
  {
    instruction: 'LSF_REG_LIT',
    opcode: 0x26,
    type: InstructionType.REG_LIT,
    size: instructionSizes.REG_LIT,
    mnemonic: 'lsf',
  },
  {
    instruction: 'LSF_REG_REG',
    opcode: 0x27,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'lsf',
  },
  {
    instruction: 'RSF_REG_LIT',
    opcode: 0x2a,
    type: InstructionType.REG_LIT,
    size: instructionSizes.REG_LIT,
    mnemonic: 'rsf',
  },
  {
    instruction: 'RSF_REG_REG',
    opcode: 0x2b,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'rsf',
  },
  {
    instruction: 'AND_REG_LIT',
    opcode: 0x2e,
    type: InstructionType.REG_LIT,
    size: instructionSizes.REG_LIT,
    mnemonic: 'and',
  },
  {
    instruction: 'AND_REG_REG',
    opcode: 0x2f,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'and',
  },
  {
    instruction: 'OR_REG_LIT',
    opcode: 0x30,
    type: InstructionType.REG_LIT,
    size: instructionSizes.REG_LIT,
    mnemonic: 'or',
  },
  {
    instruction: 'OR_REG_REG',
    opcode: 0x31,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'or',
  },
  {
    instruction: 'XOR_REG_LIT',
    opcode: 0x32,
    type: InstructionType.REG_LIT,
    size: instructionSizes.REG_LIT,
    mnemonic: 'xor',
  },
  {
    instruction: 'XOR_REG_REG',
    opcode: 0x33,
    type: InstructionType.REG_REG,
    size: instructionSizes.REG_REG,
    mnemonic: 'xor',
  },
  {
    instruction: 'NOT',
    opcode: 0x34,
    type: InstructionType.SINGLE_REG,
    size: instructionSizes.SINGLE_REG,
    mnemonic: 'not',
  },
  {
    instruction: 'JEQ_REG',
    opcode: 0x3,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'jeq',
  },
  {
    instruction: 'JEQ_LIT',
    opcode: 0x3f,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'jeq',
  },
  {
    instruction: 'JNE_REG',
    opcode: 0x4,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'jne',
  },
  {
    instruction: 'JNE_LIT',
    opcode: 0x41,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'jne',
  },
  {
    instruction: 'JLT_REG',
    opcode: 0x4,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'jlt',
  },
  {
    instruction: 'JLT_LIT',
    opcode: 0x43,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'jlt',
  },
  {
    instruction: 'JGT_REG',
    opcode: 0x4,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'jgt',
  },
  {
    instruction: 'JGT_LIT',
    opcode: 0x45,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'jgt',
  },
  {
    instruction: 'JLE_REG',
    opcode: 0x4,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'jle',
  },
  {
    instruction: 'JLE_LIT',
    opcode: 0x47,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'jle',
  },
  {
    instruction: 'JGE_REG',
    opcode: 0x4,
    type: InstructionType.REG_MEM,
    size: instructionSizes.REG_MEM,
    mnemonic: 'jge',
  },
  {
    instruction: 'JGE_LIT',
    opcode: 0x49,
    type: InstructionType.LIT_MEM,
    size: instructionSizes.LIT_MEM,
    mnemonic: 'jge',
  },
  {
    instruction: 'PSH_LIT',
    opcode: 0x17,
    type: InstructionType.SINGLE_LIT,
    size: instructionSizes.SINGLE_LIT,
    mnemonic: 'psh',
  },
  {
    instruction: 'PSH_REG',
    opcode: 0x18,
    type: InstructionType.SINGLE_REG,
    size: instructionSizes.SINGLE_REG,
    mnemonic: 'psh',
  },
  {
    instruction: 'POP',
    opcode: 0x1a,
    type: InstructionType.SINGLE_REG,
    size: instructionSizes.SINGLE_REG,
    mnemonic: 'pop',
  },
  {
    instruction: 'CAL_LIT',
    opcode: 0x5e,
    type: InstructionType.SINGLE_LIT,
    size: instructionSizes.SINGLE_LIT,
    mnemonic: 'cal',
  },
  {
    instruction: 'CAL_REG',
    opcode: 0x5f,
    type: InstructionType.SINGLE_REG,
    size: instructionSizes.SINGLE_REG,
    mnemonic: 'cal',
  },
  {
    instruction: 'RET',
    opcode: 0x60,
    type: InstructionType.NO_ARGS,
    size: instructionSizes.NO_ARGS,
    mnemonic: 'ret',
  },
  {
    instruction: 'HLT',
    opcode: 0xff,
    type: InstructionType.NO_ARGS,
    size: instructionSizes.NO_ARGS,
    mnemonic: 'hlt',
  },
]
