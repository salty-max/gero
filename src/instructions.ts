/**
 * @file instructions.ts
 * 
 * This file declares constants for various instruction codes used in the assembly language.
 * Each constant is associated with a specific byte code which represents a unique instruction.
 * The relations between the labels and the byte codes are as follows:
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
 * - JMP_NOT_EQ:        0x41, Jump if Not Equal
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

/**
 * Instruction code for 'Move Literal to Register'.
 * @constant
 * @type {number}
 */
export const MOV_LIT_REG = 0x10;

/**
 * Instruction code for 'Move Register to Register'.
 * @constant
 * @type {number}
 */
export const MOV_REG_REG = 0x11;

/**
 * Instruction code for 'Move Register to Memory'.
 * @constant
 * @type {number}
 */
export const MOV_REG_MEM = 0x12;

/**
 * Instruction code for 'Move Memory to Register'.
 * @constant
 * @type {number}
 */
export const MOV_MEM_REG = 0x13;

/**
 * Instruction code for 'Move Literal to Memory'.
 * @constant
 * @type {number}
 */
export const MOV_LIT_MEM = 0x14;

/**
 * Instruction code for 'Move Register* to Register'.
 * @constant
 * @type {number}
 */
export const MOV_REG_PTR_REG = 0x15;

/**
 * Instruction code for 'Move Value at [Literal + Register] to Register'.
 * @constant
 * @type {number}
 */
export const MOV_LIT_OFF_REG = 0x16;

/**
 * Instruction code for 'Add Literal to Register'.
 * @constant
 * @type {number}
 */
export const ADD_LIT_REG = 0x1B;

/**
 * Instruction code for 'Add Register to Register'.
 * @constant
 * @type {number}
 */
export const ADD_REG_REG = 0x1C;


/**
 * Instruction code for 'Subtract Literal from Register'.
 * @constant
 * @type {number}
 */
export const SUB_LIT_REG = 0x1D;

/**
 * Instruction code for 'Subtract Register from Literal'.
 * @constant
 * @type {number}
 */
export const SUB_REG_LIT = 0x1E;

/**
 * Instruction code for 'Subtract Register from Register'.
 * @constant
 * @type {number}
 */
export const SUB_REG_REG = 0x1F;

/**
 * Instruction code for 'Multiply Literal with Register'.
 * @constant
 * @type {number}
 */
export const MUL_LIT_REG = 0x20;

/**
 * Instruction code for 'Multiply Register with Register'.
 * @constant
 * @type {number}
 */
export const MUL_REG_REG = 0x21;

/**
 * Instruction code for 'Increment Register'.
 * @constant
 * @type {number}
 */
export const INC_REG = 0x35;

/**
 * Instruction code for 'Decrement Register'.
 * @constant
 * @type {number}
 */
export const DEC_REG = 0x36;

/**
 * Instruction code for 'Jump if Not Equal'.
 * @constant
 * @type {number}
 */
export const JMP_NOT_EQ = 0x41;

/**
 * Instruction code for 'Push Literal'.
 * @constant
 * @type {number}
 */
export const PSH_LIT = 0x17;

/**
 * Instruction code for 'Push Register'.
 * @constant
 * @type {number}
 */
export const PSH_REG = 0x18;

/**
 * Instruction code for 'Pop to Register'.
 * @constant
 * @type {number}
 */
export const POP = 0x1A;

/**
 * Instruction code for 'Call Literal'.
 * @constant
 * @type {number}
 */
export const CAL_LIT = 0x5E;

/**
 * Instruction code for 'Call Register'.
 * @constant
 * @type {number}
 */
export const CAL_REG = 0x5F;

/**
 * Instruction code for 'Return'.
 * @constant
 * @type {number}
 */
export const RET = 0x60;

/**
 * Instruction code for 'Halt'.
 * @constant
 * @type {number}
 */
export const HLT = 0xFF;
