/**
 * @file instructions.ts
 * 
 * This file declares constants for various instruction codes used in the assembly language.
 * Each constant is associated with a specific byte code which represents a unique operation.
 * The relations between the labels and the byte codes are as follows:
 * 
 * - MOV_LIT_REG:   0x10, Move Literal to Register
 * - MOV_REG_REG:   0x11, Move Register to Register
 * - MOV_REG_MEM:   0x12, Move Register to Memory
 * - MOV_MEM_REG:   0x13, Move Memory to Register
 * - ADD_REG_REG:   0x14, Add Register to Register
 * - JMP_NOT_EQ:    0x15, Jump if Not Equal
 * - PSH_LIT:       0x17, Push Literal
 * - PSH_REG:       0x18, Push Register
 * - POP:           0x1A, Pop to Register
 * - CAL_LIT:       0x5E, Call Literal
 * - CAL_REG:       0x5F, Call Register
 * - RET:           0x60, Return
 * 
 * Each byte code is represented in hexadecimal format.
 */

/**
 * Instruction code for the operation 'Move Literal to Register'.
 * @constant
 * @type {number}
 */
export const MOV_LIT_REG = 0x10;

/**
 * Instruction code for the operation 'Move Register to Register'.
 * @constant
 * @type {number}
 */
export const MOV_REG_REG = 0x11;

/**
 * Instruction code for the operation 'Move Register to Memory'.
 * @constant
 * @type {number}
 */
export const MOV_REG_MEM = 0x12;

/**
 * Instruction code for the operation 'Move Memory to Register'.
 * @constant
 * @type {number}
 */
export const MOV_MEM_REG = 0x13;

/**
 * Instruction code for the operation 'Add Register to Register'.
 * @constant
 * @type {number}
 */
export const ADD_REG_REG = 0x14;

/**
 * Instruction code for the operation 'Jump if Not Equal'.
 * @constant
 * @type {number}
 */
export const JMP_NOT_EQ = 0x15;

/**
 * Instruction code for the operation 'Push Literal'.
 * @constant
 * @type {number}
 */
export const PSH_LIT = 0x17;

/**
 * Instruction code for the operation 'Push Register'.
 * @constant
 * @type {number}
 */
export const PSH_REG = 0x18;

/**
 * Instruction code for the operation 'Pop to Register'.
 * @constant
 * @type {number}
 */
export const POP = 0x1A;

/**
 * Instruction code for the operation 'Call Literal'.
 * @constant
 * @type {number}
 */
export const CAL_LIT = 0x5E;

/**
 * Instruction code for the operation 'Call Register'.
 * @constant
 * @type {number}
 */
export const CAL_REG = 0x5F;

/**
 * Instruction code for the operation 'Return'.
 * @constant
 * @type {number}
 */
export const RET = 0x60;
