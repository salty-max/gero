/**
 * @file instructions.ts
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
 * Instruction code for 'Left shift Register by Literal'.
 * @constant
 * @type {number}
 */
export const LSF_REG_LIT = 0x26;

/**
 * Instruction code for 'Left shift Register by Register'.
 * @constant
 * @type {number}
 */
export const LSF_REG_REG = 0x27;

/**
 * Instruction code for 'Right shift Register by Literal'.
 * @constant
 * @type {number}
 */
export const RSF_REG_LIT = 0x2A;

/**
 * Instruction code for 'Right shift Register by Register'.
 * @constant
 * @type {number}
 */
export const RSF_REG_REG = 0x2B;

/**
 * Instruction code for 'And Register by Literal'.
 * @constant
 * @type {number}
 */
export const AND_REG_LIT = 0x2E;

/**
 * Instruction code for 'And Register by Register'.
 * @constant
 * @type {number}
 */
export const AND_REG_REG = 0x2F;

/**
 * Instruction code for 'Or Register by Literal'.
 * @constant
 * @type {number}
 */
export const OR_REG_LIT = 0x30;

/**
 * Instruction code for 'Or Register by Register'.
 * @constant
 * @type {number}
 */
export const OR_REG_REG = 0x31;

/**
 * Instruction code for 'Xor Register by Literal'.
 * @constant
 * @type {number}
 */
export const XOR_REG_LIT = 0x32;

/**
 * Instruction code for 'Xor Register by Register'.
 * @constant
 * @type {number}
 */
export const XOR_REG_REG = 0x33;

/**
 * Instruction code for 'Not'.
 * @constant
 * @type {number}
 */
export const NOT = 0x34;

/**
 * Instruction code for 'Jump if Not Equal (JEQ_REG)'.
 * @constant
 * @type {number}
 */

export const JEQ_REG = 0x3E;
/**
 * Instruction code for 'Jump if Equal (JEQ_LIT)'.
 * @constant
 * @type {number}
 */
export const JEQ_LIT = 0x3F;

/**
 * Instruction code for 'Jump if Equal (JNE_REG)'.
 * @constant
 * @type {number}
 */

export const JNE_REG = 0x40;
/**
 * Instruction code for 'Jump if Not Equal (JNE_LIT)'.
 * @constant
 * @type {number}
 */
export const JNE_LIT = 0x41;

/**
 * Instruction code for 'Jump if Lesser Than (JLT_REG)'.
 * @constant
 * @type {number}
 */

export const JLT_REG = 0x42;
/**
 * Instruction code for 'Jump if Lesser Than (JLT_LIT)'.
 * @constant
 * @type {number}
 */
export const JLT_LIT = 0x43;

/**
 * Instruction code for 'Jump if Greater Than (JGT_REG)'.
 * @constant
 * @type {number}
 */

export const JGT_REG = 0x44;
/**
 * Instruction code for 'Jump if Greater Than (JGT_LIT)'.
 * @constant
 * @type {number}
 */
export const JGT_LIT = 0x45;

/**
 * Instruction code for 'Jump if Lesser Than Or Equal (JLE_REG)'.
 * @constant
 * @type {number}
 */

export const JLE_REG = 0x46;
/**
 * Instruction code for 'Jump if Lesser Than Or Equal (JLE_LIT)'.
 * @constant
 * @type {number}
 */
export const JLE_LIT = 0x47;

/**
 * Instruction code for 'Jump if Greater Than Or Equal (JGE_REG)'.
 * @constant
 * @type {number}
 */

export const JGE_REG = 0x48;
/**
 * Instruction code for 'Jump if Greater Than Or Equal (JGE_LIT)'.
 * @constant
 * @type {number}
 */
export const JGE_LIT = 0x49;

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
