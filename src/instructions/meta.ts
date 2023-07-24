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
 * - MOV_REG_REG_PTR:   0x16, Move Register to Register*
 * - MOV_LIT_OFF_REG:   0x17, Move Value at [Literal + Register] to Register
 * - MOV8_LIT_REG:      0x70, Move 8-bit Literal to Register
 * - MOV8_MEM_REG:      0x71, Move 8-bit Memory to Register
 * - MOVL_REG_MEM:      0x72, Move Low 8-bit Register to Memory
 * - MOVH_REG_MEM:      0x73, Move High 8-bit Register to Memory
 * - MOV8_REG_PTR_REG:  0x74, Move 8-bit Register* to Register
 * - MOV8_REG_REG_PTR:  0x75, Move 8-bit Register to Register*
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
 * - NEG_REG:           0x37, Negate Register
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
 * - PSH_LIT:           0x18, Push Literal
 * - PSH_REG:           0x19, Push Register
 * - POP:               0x1A, Pop to Register
 * Subroutines instructions
 * - CAL_LIT:           0x5E, Call Literal
 * - CAL_REG:           0x5F, Call Register
 * - RET:               0x60, Return
 * System instructions
 * - BRK:               0xFB, Breakpoint
 * - INT:               0xFC, Interrupt
 * - RET_INT:           0xFD, Return from Interrupt
 * - HLT:               0xFF, Halt
 *
 * Each byte code is represented in hexadecimal format.
 */

export const instructionTypes = {
  litReg: 0,
  regLit: 1,
  regLit8: 2,
  regReg: 3,
  regMem: 4,
  memReg: 5,
  litMem: 6,
  litMem8: 7,
  regPtrReg: 8,
  litOffReg: 9,
  noArgs: 10,
  singleReg: 11,
  singleLit: 12,
  singleAddr: 13,
  regRegPtr: 14,
  litRegPtr: 15,
  regPtrMem: 16,
}

const instructionSizes = {
  litReg: 4,
  litRegPtr: 4,
  regLit: 4,
  regLit8: 3,
  regReg: 3,
  regMem: 4,
  memReg: 4,
  litMem: 5,
  litMem8: 4,
  regPtrReg: 3,
  regRegPtr: 3,
  litOffReg: 5,
  noArgs: 1,
  singleReg: 2,
  singleLit: 3,
  singleAddr: 3,
}

export interface IMeta {
  instruction: string
  opcode: number
  type: number
  size: number
  mnemonic: string
}

export const meta: Array<IMeta> = [
  {
    instruction: 'MOV8_LIT_MEM',
    opcode: 0x70,
    type: instructionTypes.litMem8,
    size: instructionSizes.litMem8,
    mnemonic: 'mov8',
  },
  {
    instruction: 'MOV8_MEM_REG',
    opcode: 0x71,
    type: instructionTypes.memReg,
    size: instructionSizes.memReg,
    mnemonic: 'mov8',
  },
  {
    instruction: 'MOVL_REG_MEM',
    opcode: 0x72,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'movl',
  },
  {
    instruction: 'MOVH_REG_MEM',
    opcode: 0x73,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'movh',
  },
  {
    instruction: 'MOV8_REG_PTR_REG',
    opcode: 0x74,
    type: instructionTypes.regPtrReg,
    size: instructionSizes.regPtrReg,
    mnemonic: 'mov8',
  },
  {
    instruction: 'MOV8_REG_REG_PTR',
    opcode: 0x75,
    type: instructionTypes.regRegPtr,
    size: instructionSizes.regRegPtr,
    mnemonic: 'mov8',
  },
  {
    instruction: 'MOV_LIT_REG',
    opcode: 0x10,
    type: instructionTypes.litReg,
    size: instructionSizes.litReg,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_REG',
    opcode: 0x11,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_MEM',
    opcode: 0x12,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_MEM_REG',
    opcode: 0x13,
    type: instructionTypes.memReg,
    size: instructionSizes.memReg,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_LIT_MEM',
    opcode: 0x14,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_PTR_REG',
    opcode: 0x15,
    type: instructionTypes.regPtrReg,
    size: instructionSizes.regPtrReg,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_REG_REG_PTR',
    opcode: 0x16,
    type: instructionTypes.regRegPtr,
    size: instructionSizes.regRegPtr,
    mnemonic: 'mov',
  },
  {
    instruction: 'MOV_LIT_OFF_REG',
    opcode: 0x17,
    type: instructionTypes.litOffReg,
    size: instructionSizes.litOffReg,
    mnemonic: 'mov',
  },
  {
    instruction: 'ADD_LIT_REG',
    opcode: 0x1b,
    type: instructionTypes.litReg,
    size: instructionSizes.litReg,
    mnemonic: 'add',
  },
  {
    instruction: 'ADD_REG_REG',
    opcode: 0x1c,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'add',
  },
  {
    instruction: 'SUB_LIT_REG',
    opcode: 0x1d,
    type: instructionTypes.litReg,
    size: instructionSizes.litReg,
    mnemonic: 'sub',
  },
  {
    instruction: 'SUB_REG_LIT',
    opcode: 0x1e,
    type: instructionTypes.regLit,
    size: instructionSizes.regLit,
    mnemonic: 'sub',
  },
  {
    instruction: 'SUB_REG_REG',
    opcode: 0x1f,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'sub',
  },
  {
    instruction: 'MUL_LIT_REG',
    opcode: 0x20,
    type: instructionTypes.litReg,
    size: instructionSizes.litReg,
    mnemonic: 'mul',
  },
  {
    instruction: 'MUL_REG_REG',
    opcode: 0x21,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'mul',
  },
  {
    instruction: 'INC_REG',
    opcode: 0x35,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'inc',
  },
  {
    instruction: 'DEC_REG',
    opcode: 0x36,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'dec',
  },
  {
    instruction: 'NEG_REG',
    opcode: 0x37,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'neg',
  },
  {
    instruction: 'LSF_REG_LIT',
    opcode: 0x26,
    type: instructionTypes.regLit,
    size: instructionSizes.regLit,
    mnemonic: 'lsf',
  },
  {
    instruction: 'LSF_REG_REG',
    opcode: 0x27,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'lsf',
  },
  {
    instruction: 'RSF_REG_LIT',
    opcode: 0x2a,
    type: instructionTypes.regLit,
    size: instructionSizes.regLit,
    mnemonic: 'rsf',
  },
  {
    instruction: 'RSF_REG_REG',
    opcode: 0x2b,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'rsf',
  },
  {
    instruction: 'AND_REG_LIT',
    opcode: 0x2e,
    type: instructionTypes.regLit,
    size: instructionSizes.regLit,
    mnemonic: 'and',
  },
  {
    instruction: 'AND_REG_REG',
    opcode: 0x2f,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'and',
  },
  {
    instruction: 'OR_REG_LIT',
    opcode: 0x30,
    type: instructionTypes.regLit,
    size: instructionSizes.regLit,
    mnemonic: 'or',
  },
  {
    instruction: 'OR_REG_REG',
    opcode: 0x31,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'or',
  },
  {
    instruction: 'XOR_REG_LIT',
    opcode: 0x32,
    type: instructionTypes.regLit,
    size: instructionSizes.regLit,
    mnemonic: 'xor',
  },
  {
    instruction: 'XOR_REG_REG',
    opcode: 0x33,
    type: instructionTypes.regReg,
    size: instructionSizes.regReg,
    mnemonic: 'xor',
  },
  {
    instruction: 'NOT',
    opcode: 0x34,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'not',
  },
  {
    instruction: 'JEQ_REG',
    opcode: 0x3e,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'jeq',
  },
  {
    instruction: 'JEQ_LIT',
    opcode: 0x3f,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'jeq',
  },
  {
    instruction: 'JNE_REG',
    opcode: 0x40,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'jne',
  },
  {
    instruction: 'JNE_LIT',
    opcode: 0x41,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'jne',
  },
  {
    instruction: 'JLT_REG',
    opcode: 0x42,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'jlt',
  },
  {
    instruction: 'JLT_LIT',
    opcode: 0x43,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'jlt',
  },
  {
    instruction: 'JGT_REG',
    opcode: 0x44,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'jgt',
  },
  {
    instruction: 'JGT_LIT',
    opcode: 0x45,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'jgt',
  },
  {
    instruction: 'JLE_REG',
    opcode: 0x46,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'jle',
  },
  {
    instruction: 'JLE_LIT',
    opcode: 0x47,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'jle',
  },
  {
    instruction: 'JGE_REG',
    opcode: 0x48,
    type: instructionTypes.regMem,
    size: instructionSizes.regMem,
    mnemonic: 'jge',
  },
  {
    instruction: 'JGE_LIT',
    opcode: 0x49,
    type: instructionTypes.litMem,
    size: instructionSizes.litMem,
    mnemonic: 'jge',
  },
  {
    instruction: 'PSH_LIT',
    opcode: 0x18,
    type: instructionTypes.singleLit,
    size: instructionSizes.singleLit,
    mnemonic: 'psh',
  },
  {
    instruction: 'PSH_REG',
    opcode: 0x19,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'psh',
  },
  {
    instruction: 'POP',
    opcode: 0x1a,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'pop',
  },
  {
    instruction: 'CAL_LIT',
    opcode: 0x5e,
    type: instructionTypes.singleAddr,
    size: instructionSizes.singleAddr,
    mnemonic: 'cal',
  },
  {
    instruction: 'CAL_REG',
    opcode: 0x5f,
    type: instructionTypes.singleReg,
    size: instructionSizes.singleReg,
    mnemonic: 'cal',
  },
  {
    instruction: 'RET',
    opcode: 0x60,
    type: instructionTypes.noArgs,
    size: instructionSizes.noArgs,
    mnemonic: 'ret',
  },
  {
    instruction: 'BRK',
    opcode: 0xfb,
    type: instructionTypes.noArgs,
    size: instructionSizes.noArgs,
    mnemonic: 'brk',
  },
  {
    instruction: 'INT',
    opcode: 0xfc,
    type: instructionTypes.singleLit,
    size: instructionSizes.singleLit,
    mnemonic: 'int',
  },
  {
    instruction: 'RET_INT',
    opcode: 0xfd,
    type: instructionTypes.noArgs,
    size: instructionSizes.noArgs,
    mnemonic: 'rti',
  },
  {
    instruction: 'HLT',
    opcode: 0xff,
    type: instructionTypes.noArgs,
    size: instructionSizes.noArgs,
    mnemonic: 'hlt',
  },
]
