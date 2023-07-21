/**
 * @file CPU.ts
 *
 * This class emulates a 16-bit CPU, operating on an array of 16-bit values as
 * memory. It includes a stack and an instruction set.
 *
 * @see CPU
 */

import instructions from './instructions'
import { logWithFormat } from '../util/logger'
import { createMemory } from './memory'
import { MemoryMapper } from './memory-mapper'
import {
  ANSI_COLOR_BLUE,
  ANSI_COLOR_BOLD,
  ANSI_COLOR_GREEN,
  ANSI_COLOR_RESET,
  GENERIC_REGISTERS_COUNT,
  REGISTER_NAMES,
} from '../util/util'

/**
 * Class that emulates a 16-bit CPU.
 */
export class CPU {
  /**
   * The memory of the CPU, represented as a MemoryMapper.
   * @private
   * @type {MemoryMapper}
   */
  private memory: MemoryMapper
  /**
   * An array of register names for the CPU.
   * @private
   * @type {Array<string>}
   */
  private registerNames: Array<string> = []
  /**
   * The registers of the CPU, represented as a DataView.
   * @private
   * @type {DataView}
   */
  private registers: DataView
  /**
   * A mapping from register names to their memory addresses.
   * @private
   * @type {Record<string, number>}
   */
  private registerMap: Record<string, number>
  /**
   * The internal stack frame size pointer of the CPU.
   * @private
   * @type {number}
   */
  private stackFrameSize: number = 0

  /**
   * Constructor for the CPU class.
   * @param {MemoryMapper} memory - The memory for the CPU.
   * @constructor
   */
  constructor(memory: MemoryMapper) {
    this.memory = memory

    this.registerNames = REGISTER_NAMES

    this.registers = createMemory(this.registerNames.length * 2) // Create DataView for registers
    this.registerMap = this.registerNames.reduce(
      (map: Record<string, number>, name: string, i: number) => {
        map[name] = i * 2 // Assign memory address to each register
        return map
      },
      {}
    )

    /**
     * Initialize the "sp" (stack pointer) and "fp" (frame pointer) registers.
     * These pointers are set to point to the very end of the memory to initiate an empty stack,
     * which grows towards decreasing memory addresses.
     * They are initialized at 0xffff - 1 (0xfffe).
     */
    this.setRegister('sp', 0xffff - 1)
    this.setRegister('fp', 0xffff - 1)
  }

  /**
   * Prints current register state for debugging purposes.
   */
  debug() {
    logWithFormat(
      'REGISTER\n----------------\n',
      ANSI_COLOR_BOLD,
      ANSI_COLOR_GREEN
    )

    this.registerNames.forEach((name) => {
      console.log(
        `${name}: ${ANSI_COLOR_BLUE}${ANSI_COLOR_BOLD}0x${this.getRegister(name)
          .toString(16)
          .padStart(4, '0')}${ANSI_COLOR_RESET}`
      )
    })
    console.log()
  }

  /**
   * Prints the n bytes in memory starting from a specific address for debugging purposes.
   *
   * @param {number} address - The starting memory address.
   * @param {number} [n=8] - Number of bytes to display.
   */
  viewMemoryAt(address: number, n = 8) {
    const nextNBytes = Array.from({ length: n }, (_, i) => {
      return this.memory.getUint8(address + i)
    }).map((v) => `0x${v.toString(16).padStart(2, '0')}`)

    logWithFormat(
      'MEMORY AT\n----------------\n',
      ANSI_COLOR_BOLD,
      ANSI_COLOR_GREEN
    )
    console.log(
      `${ANSI_COLOR_BLUE}${ANSI_COLOR_BOLD}0x${address
        .toString(16)
        .padStart(4, '0')}${ANSI_COLOR_RESET}: ${nextNBytes.join(' ')}`
    )
  }

  /**
   * Retrieves the 16-bit value stored in a register by its name.
   *
   * @param {string} name - Name of the register.
   * @returns {number} - The 16-bit value stored in the register.
   * @throws {Error} - Throws an error if the register name is invalid.
   */
  getRegister(name: string): number {
    if (!(name in this.registerMap)) {
      throw new Error(`getRegister: No such register ${name}`)
    }

    return this.registers.getUint16(this.registerMap[name])
  }

  /**
   * Stores a 16-bit value into a register by its name.
   *
   * @param {string} name - Name of the register.
   * @param {number} value - The 16-bit value to store in the register.
   * @throws {Error} - Throws an error if the register name is invalid.
   */
  setRegister(name: string, value: number) {
    if (!(name in this.registerMap)) {
      throw new Error(`setRegister: No such register ${name}`)
    }

    return this.registers.setUint16(this.registerMap[name], value)
  }

  /**
   * Fetches the next 8-bit instruction from memory and increment the instruction pointer.
   * @private
   * @returns {number} - The fetched 8-bit instruction.
   */
  private fetch(): number {
    const nextInstructionAddress = this.getRegister('ip')
    const instruction = this.memory.getUint8(nextInstructionAddress)

    this.setRegister('ip', nextInstructionAddress + 1)

    return instruction
  }

  /**
   * Fetches the next 16-bit instruction (or a data word) from memory and increment the instruction pointer.
   * @private
   * @returns {number} - The fetched 16-bit instruction or data word.
   */
  private fetch16(): number {
    const nextInstructionAddress = this.getRegister('ip')
    const instruction = this.memory.getUint16(nextInstructionAddress)

    this.setRegister('ip', nextInstructionAddress + 2)

    return instruction
  }

  /**
   * Pushes a 16-bit value onto the stack and decrement the stack pointer.
   * @private
   * @param {number} value - The 16-bit value to push onto the stack.
   */
  private push(value: number) {
    const spAddress = this.getRegister('sp')

    this.memory.setUint16(spAddress, value)
    this.setRegister('sp', spAddress - 2)
    this.stackFrameSize += 2
  }

  /**
   * Saves the current CPU state (registers and return address) onto the stack.
   * @private
   */
  private pushState() {
    // Push generic registers' current state onto the stack
    for (let i = 1; i <= GENERIC_REGISTERS_COUNT; i++) {
      this.push(this.getRegister(`r${i}`))
    }
    // Push instruction pointer onto the stack as a return address for the subroutine
    this.push(this.getRegister('ip'))
    // Push current stack frame size + 2 bytes for this pointer
    this.push(this.stackFrameSize + 2)

    // Set frame pointer to current stack pointer
    this.setRegister('fp', this.getRegister('sp'))
    // Reset stack frame size pointer to allow another subroutine to use it
    this.stackFrameSize = 0
  }

  /**
   * Pops a 16-bit value from the stack and increment the stack pointer.
   * @private
   * @returns {number} - The popped 16-bit value.
   */
  private pop(): number {
    const nextSpAddress = this.getRegister('sp') + 2

    this.setRegister('sp', nextSpAddress)
    this.stackFrameSize -= 2

    return this.memory.getUint16(nextSpAddress)
  }

  /**
   * Restores the CPU state (registers and return address) from the stack.
   * @private
   */
  private popState() {
    const framePointerAddress = this.getRegister('fp')
    this.setRegister('sp', framePointerAddress)
    this.stackFrameSize = this.pop()
    const currentStackFrameSize = this.stackFrameSize

    this.setRegister('ip', this.pop())
    for (let i = GENERIC_REGISTERS_COUNT; i >= 1; i--) {
      this.setRegister(`r${i}`, this.pop())
    }

    const nArgs = this.pop()
    for (let i = 0; i < nArgs; i++) {
      this.pop()
    }
    this.setRegister('fp', framePointerAddress + currentStackFrameSize)
  }

  /**
   * Fetches the next byte from memory, interpret it as a register index, and return it.
   * @private
   * @returns {number} - The fetched register index.
   */
  private fetchRegisterIndex() {
    return (this.fetch() % this.registerNames.length) * 2
  }

  /**
   * Executes a given instruction.
   * @private
   * @param {number} instruction - The opcode of the instruction to execute.
   * @returns {boolean} Whether the computation should stop
   */
  private execute(instruction: number): boolean {
    switch (instruction) {
      /**
       * Move Literal to Register (MOV_LIT_REG) instruction.
       * Fetches a literal 16-bit value and a register index from the instruction stream,
       * and then sets the fetched literal value into the specified register.
       */
      case instructions.MOV_LIT_REG.opcode: {
        const literal = this.fetch16()
        const register = this.fetchRegisterIndex()

        this.registers.setUint16(register, literal)
        return false
      }
      /**
       * Move Register to Register (MOV_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream,
       * reads the value from the first (source) register,
       * and then sets that value into the second (destination) register.
       */
      case instructions.MOV_REG_REG.opcode: {
        const registerFrom = this.fetchRegisterIndex()
        const registerTo = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerFrom)

        this.registers.setUint16(registerTo, value)
        return false
      }
      /**
       * Move Register to Memory (MOV_REG_MEM) instruction.
       * Fetches a register index and a memory address from the instruction stream,
       * reads the value from the specified register,
       * and then sets that value into the specified memory address.
       */
      case instructions.MOV_REG_MEM.opcode: {
        const registerFrom = this.fetchRegisterIndex()
        const address = this.fetch16()
        const value = this.registers.getUint16(registerFrom)

        this.memory.setUint16(address, value)
        return false
      }
      /**
       * Move Memory to Register (MOV_MEM_REG) instruction.
       * Fetches a memory address and a register index from the instruction stream,
       * reads the value from the specified memory address,
       * and then sets that value into the specified register.
       */
      case instructions.MOV_MEM_REG.opcode: {
        const address = this.fetch16()
        const registerTo = this.fetchRegisterIndex()
        const value = this.memory.getUint16(address)

        this.registers.setUint16(registerTo, value)
        return false
      }
      /**
       * Move Literal to Memory (MOV_LIT_MEM) instruction.
       * Fetches a literal 16-bit value and a memory address from the instruction stream,
       * and then sets the fetched literal value into the specified memory address.
       */
      case instructions.MOV_LIT_MEM.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        this.memory.setUint16(address, value)
        return false
      }
      /**
       * Move Register* to Register (MOV_REG_PTR_REG) instruction.
       * Fetches two register indexes from the instruction stream,
       * reads a memory address from the first (source) register (treats it as a pointer),
       * fetches the value from the fetched memory address,
       * and then sets that value into the second (destination) register.
       */
      case instructions.MOV_REG_PTR_REG.opcode: {
        const registerFrom = this.fetchRegisterIndex()
        const registerTo = this.fetchRegisterIndex()
        const ptr = this.registers.getUint16(registerFrom)
        const value = this.memory.getUint16(ptr)

        this.registers.setUint16(registerTo, value)
        return false
      }
      /**
       * Move Literal Offset to Register (MOV_LIT_OFF_REG) instruction.
       * Fetches a base memory address and two register indexes from the instruction stream,
       * reads an offset from the first (source) register,
       * fetches the value from the memory address calculated by adding the offset to the base address,
       * and then sets that value into the second (destination) register.
       */
      case instructions.MOV_LIT_OFF_REG.opcode: {
        const baseAddress = this.fetch16()
        const registerFrom = this.fetchRegisterIndex()
        const registerTo = this.fetchRegisterIndex()
        const offset = this.registers.getUint16(registerFrom)
        const value = this.memory.getUint16(baseAddress + offset)

        this.registers.setUint16(registerTo, value)
        return false
      }
      /**
       * Add Register to Register (ADD_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream,
       * reads the values from the two registers,
       * adds these values, and then stores the result into the accumulator (acc) register.
       */
      case instructions.ADD_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const registerValue1 = this.registers.getUint16(r1)
        const registerValue2 = this.registers.getUint16(r2)

        this.setRegister('acc', registerValue1 + registerValue2)
        return false
      }
      /**
       * Add Literal to Register (ADD_LIT_REG) instruction.
       * Fetches a literal 16-bit value and a register index from the instruction stream,
       * reads the value from the fetched register,
       * adds the literal to the fetched value, and then stores the result in the accumulator (acc) register.
       */
      case instructions.ADD_LIT_REG.opcode: {
        const literal = this.fetch16()
        const registerIndex = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerIndex)

        this.setRegister('acc', literal + value)
        return false
      }
      /**
       * Subtract Literal from Register (SUB_LIT_REG) instruction.
       * Fetches a literal 16-bit value and a register index from the instruction stream,
       * reads the value from the fetched register,
       * subtracts the fetched value from the literal, and then stores the result in the accumulator (acc) register.
       */
      case instructions.SUB_LIT_REG.opcode: {
        const literal = this.fetch16()
        const registerIndex = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerIndex)

        this.setRegister('acc', literal - value)
        return false
      }
      /**
       * Subtract Literal from Register (SUB_REG_LIT) instruction.
       * Fetches a register index and a literal 16-bit value from the instruction stream,
       * reads the value from the fetched register,
       * subtracts the literal from the fetched value, and then stores the result in the accumulator (acc) register.
       */
      case instructions.SUB_REG_LIT.opcode: {
        const registerIndex = this.fetchRegisterIndex()
        const literal = this.fetch16()
        const value = this.registers.getUint16(registerIndex)

        this.setRegister('acc', value - literal)
        return false
      }
      /**
       * Subtract Register from Register (SUB_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream,
       * reads the values from the two registers,
       * subtracts the second value from the first one, and then stores the result in the accumulator (acc) register.
       */
      case instructions.SUB_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const r1Value = this.registers.getUint16(r1)
        const r2Value = this.registers.getUint16(r2)

        this.setRegister('acc', r1Value - r2Value)
        return false
      }
      /**
       * Multiply Literal with Register (MUL_LIT_REG) instruction.
       * Fetches a literal 16-bit value and a register index from the instruction stream,
       * reads the value from the fetched register,
       * multiplies the literal with the fetched value, and then stores the result in the accumulator (acc) register.
       */
      case instructions.MUL_LIT_REG.opcode: {
        const literal = this.fetch16()
        const registerIndex = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerIndex)

        this.setRegister('acc', literal * value)
        return false
      }
      /**
       * Multiply Register with Register (MUL_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream,
       * reads the values from the two registers,
       * multiplies the two values, and then stores the result in the accumulator (acc) register.
       */
      case instructions.MUL_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const r1Value = this.registers.getUint16(r1)
        const r2Value = this.registers.getUint16(r2)

        this.setRegister('acc', r1Value * r2Value)
        return false
      }
      /**
       * Increment Register (INC_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the fetched register,
       * increments the fetched value, and then stores the result back into the register.
       */
      case instructions.INC_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const value = this.registers.getUint16(r)

        this.registers.setUint16(r, value + 1)
        return false
      }
      /**
       * Decrement Register (DEC_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the fetched register,
       * decrements the fetched value, and then stores the result back into the register.
       */
      case instructions.DEC_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const value = this.registers.getUint16(r)

        this.registers.setUint16(r, value - 1)
        return false
      }
      /**
       * Left Shift Register by Literal (LSF_REG_LIT) instruction.
       * Fetches a register index and a literal value from the instruction stream.
       * Left shifts the value in the register by the specified literal value,
       * and then stores the result back into the register.
       */
      case instructions.LSF_REG_LIT.opcode: {
        const r = this.fetchRegisterIndex()
        const literal = this.fetch()
        const rValue = this.registers.getUint16(r)

        this.registers.setUint16(r, rValue << literal)
        return false
      }
      /**
       * Left Shift Register by Register (LSF_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream.
       * Left shifts the value in the first register by the value in the second register,
       * and then stores the result back into the first register.
       */
      case instructions.LSF_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const v1 = this.registers.getUint16(r1)
        const v2 = this.registers.getUint16(r2)

        this.registers.setUint16(r1, v1 << v2)
        return false
      }
      /**
       * Right Shift Register by Literal (RSF_REG_LIT) instruction.
       * Fetches a register index and a literal value from the instruction stream.
       * Right shifts the value in the register by the specified literal value,
       * and then stores the result back into the register.
       */
      case instructions.RSF_REG_LIT.opcode: {
        const r = this.fetchRegisterIndex()
        const literal = this.fetch()
        const rValue = this.registers.getUint16(r)

        this.registers.setUint16(r, rValue >> literal)
        return false
      }
      /**
       * Right Shift Register by Register (RSF_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream.
       * Right shifts the value in the first register by the value in the second register,
       * and then stores the result back into the first register.
       */
      case instructions.RSF_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const v1 = this.registers.getUint16(r1)
        const v2 = this.registers.getUint16(r2)

        this.registers.setUint16(r1, v1 >> v2)
        return false
      }
      /**
       * Bitwise AND Register with Literal (AND_REG_LIT) instruction.
       * Fetches a register index and a literal value from the instruction stream.
       * Performs a bitwise AND operation between the value in the register and the literal value,
       * and then stores the result in the accumulator (acc) register.
       */

      case instructions.AND_REG_LIT.opcode: {
        const r = this.fetchRegisterIndex()
        const literal = this.fetch()
        const rValue = this.registers.getUint16(r)

        this.setRegister('acc', rValue & literal)
        return false
      }
      /**
       * Bitwise AND Register with Register (AND_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream.
       * Performs a bitwise AND operation between the values in the two registers,
       * and then stores the result in the accumulator (acc) register.
       */
      case instructions.AND_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const v1 = this.registers.getUint16(r1)
        const v2 = this.registers.getUint16(r2)

        this.setRegister('acc', v1 & v2)
        return false
      }
      /**
       * Bitwise OR Register with Literal (OR_REG_LIT) instruction.
       * Fetches a register index and a literal value from the instruction stream.
       * Performs a bitwise OR operation between the value in the register and the literal value,
       * and then stores the result in the accumulator (acc) register.
       */
      case instructions.OR_REG_LIT.opcode: {
        const r = this.fetchRegisterIndex()
        const literal = this.fetch()
        const rValue = this.registers.getUint16(r)

        this.setRegister('acc', rValue | literal)
        return false
      }
      /**
       * Bitwise OR Register with Register (OR_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream.
       * Performs a bitwise OR operation between the values in the two registers,
       * and then stores the result in the accumulator (acc) register.
       */
      case instructions.OR_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const v1 = this.registers.getUint16(r1)
        const v2 = this.registers.getUint16(r2)

        this.setRegister('acc', v1 | v2)
        return false
      }
      /**
       * Bitwise XOR Register with Literal (XOR_REG_LIT) instruction.
       * Fetches a register index and a literal value from the instruction stream.
       * Performs a bitwise XOR operation between the value in the register and the literal value,
       * and then stores the result in the accumulator (acc) register.
       */
      case instructions.XOR_REG_LIT.opcode: {
        const r = this.fetchRegisterIndex()
        const literal = this.fetch()
        const rValue = this.registers.getUint16(r)

        this.setRegister('acc', rValue ^ literal)
        return false
      }
      /**
       * Bitwise XOR Register with Register (XOR_REG_REG) instruction.
       * Fetches two register indexes from the instruction stream.
       * Performs a bitwise XOR operation between the values in the two registers,
       * and then stores the result in the accumulator (acc) register.
       */
      case instructions.XOR_REG_REG.opcode: {
        const r1 = this.fetchRegisterIndex()
        const r2 = this.fetchRegisterIndex()
        const v1 = this.registers.getUint16(r1)
        const v2 = this.registers.getUint16(r2)

        this.setRegister('acc', v1 ^ v2)
        return false
      }
      /**
       * Bitwise NOT (NOT) instruction.
       * Fetches a register index from the instruction stream.
       * Performs a bitwise NOT operation on the value in the register,
       * inverting all the bits (changing 0s to 1s and 1s to 0s).
       * Since JavaScript performs bitwise operations on signed 32-bit integers,
       * a bitwise AND operation with 0xffff is performed to ensure the result
       * remains within the range of a 16-bit unsigned integer.
       * This operation preserves the lower 16 bits of the result
       * and sets the upper 16 bits to 0.
       * The final result is stored in the accumulator (acc) register.
       */
      case instructions.NOT.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)

        this.setRegister('acc', ~v & 0xffff)
        return false
      }
      /**
       * Jump if Not Equal (JNE_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register (v),
       * fetches a memory address (address),
       * and compares the value in the register with the accumulator (acc) register.
       * If the values are not equal, the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JNE_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)
        const address = this.fetch16()

        if (v !== this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Not Equal (JNE_LIT) instruction.
       * Fetches a literal 16-bit value and a memory address from the instruction stream,
       * then compares the fetched value with the value in the accumulator (acc) register.
       * If the values are not equal, it sets the instruction pointer (ip) register to the fetched memory address,
       * effectively causing a jump to a new location in the instruction stream.
       */
      case instructions.JNE_LIT.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value !== this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Equal (JEQ_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register (v),
       * fetches a memory address (address),
       * and compares the value in the register with the accumulator (acc) register.
       * If the values are equal, the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JEQ_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)
        const address = this.fetch16()

        if (v === this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Equal (JEQ_LIT) instruction.
       * Fetches a literal 16-bit value (value),
       * fetches a memory address (address),
       * and compares the literal value with the accumulator (acc) register.
       * If the values are equal, the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JEQ_LIT.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value === this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Less Than (JLT_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register (v),
       * fetches a memory address (address),
       * and compares the value in the register with the accumulator (acc) register.
       * If the value in the register is less than the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JLT_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)
        const address = this.fetch16()

        if (v < this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Less Than (JLT_LIT) instruction.
       * Fetches a literal 16-bit value (value),
       * fetches a memory address (address),
       * and compares the literal value with the accumulator (acc) register.
       * If the literal value is less than the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JLT_LIT.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value < this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Greater Than (JGT_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register (v),
       * fetches a memory address (address),
       * and compares the value in the register with the accumulator (acc) register.
       * If the value in the register is greater than the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JGT_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)
        const address = this.fetch16()

        if (v > this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Greater Than (JGT_LIT) instruction.
       * Fetches a literal 16-bit value (value),
       * fetches a memory address (address),
       * and compares the literal value with the accumulator (acc) register.
       * If the literal value is greater than the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JGT_LIT.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value > this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Less Than or Equal (JLE_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register (v),
       * fetches a memory address (address),
       * and compares the value in the register with the accumulator (acc) register.
       * If the value in the register is less than or equal to the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JLE_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)
        const address = this.fetch16()

        if (v <= this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Less Than or Equal (JLE_LIT) instruction.
       * Fetches a literal 16-bit value (value),
       * fetches a memory address (address),
       * and compares the literal value with the accumulator (acc) register.
       * If the literal value is less than or equal to the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JLE_LIT.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value <= this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Greater Than or Equal (JGE_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register (v),
       * fetches a memory address (address),
       * and compares the value in the register with the accumulator (acc) register.
       * If the value in the register is greater than or equal to the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JGE_REG.opcode: {
        const r = this.fetchRegisterIndex()
        const v = this.registers.getUint16(r)
        const address = this.fetch16()

        if (v >= this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Jump if Greater Than or Equal (JGE_LIT) instruction.
       * Fetches a literal 16-bit value (value),
       * fetches a memory address (address),
       * and compares the literal value with the accumulator (acc) register.
       * If the literal value is greater than or equal to the value in the accumulator,
       * the instruction pointer (ip) register is set to the fetched memory address,
       * causing a jump to a new location in the instruction stream.
       */
      case instructions.JGE_LIT.opcode: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value >= this.getRegister('acc')) {
          this.setRegister('ip', address)
        }

        return false
      }
      /**
       * Push Literal (PSH_LIT) instruction.
       * Fetches a literal 16-bit value from the instruction stream,
       * and then pushes it onto the stack.
       */
      case instructions.PSH_LIT.opcode: {
        const value = this.fetch16()

        this.push(value)
        return false
      }
      /**
       * Push Register (PSH_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register,
       * and then pushes it onto the stack.
       */
      case instructions.PSH_REG.opcode: {
        const registerFrom = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerFrom)

        this.push(value)
        return false
      }
      /**
       * Pop to Register (POP) instruction.
       * Fetches a register index from the instruction stream,
       * pops a value from the stack,
       * and then sets the popped value into the specified register.
       */
      case instructions.POP.opcode: {
        const registerIndex = this.fetchRegisterIndex()
        const value = this.pop()

        this.registers.setUint16(registerIndex, value)
        return false
      }
      /**
       * Call Literal (CAL_LIT) instruction.
       * Fetches a memory address from the instruction stream,
       * pushes the current state onto the stack (for returning later),
       * and then sets the instruction pointer (ip) register to the fetched memory address,
       * effectively causing a jump to a new location in the instruction stream.
       */
      case instructions.CAL_LIT.opcode: {
        const address = this.fetch16()

        this.pushState()
        this.setRegister('ip', address)
        return false
      }
      /**
       * Call Register (CAL_REG) instruction.
       * Fetches a register index from the instruction stream,
       * reads a memory address from the specified register,
       * pushes the current state onto the stack (for returning later),
       * and then sets the instruction pointer (ip) register to the read memory address,
       * effectively causing a jump to a new location in the instruction stream.
       */
      case instructions.CAL_REG.opcode: {
        const registerIndex = this.fetchRegisterIndex()
        const address = this.registers.getUint16(registerIndex)

        this.pushState()
        this.setRegister('ip', address)
        return false
      }
      /**
       * Return (RET) instruction.
       * Pops the previously pushed state from the stack,
       * effectively causing a jump back to the location in the instruction stream from where the subroutine was called.
       */
      case instructions.RET.opcode: {
        this.popState()
        return false
      }
      /**
       * Halt (HLT) instruction.
       * Tells the CPU to stop all computation.
       */
      case instructions.HLT.opcode:
        return true

      default:
        return false
    }
  }

  /**
   * Executes a single step: fetch the next instruction and execute it.
   */
  step() {
    const instruction = this.fetch()
    return this.execute(instruction)
  }

  /**
   * Executes all computations until HLT instruction.
   */
  run() {
    const halt = this.step()
    if (!halt) {
      setImmediate(() => this.run())
    }
  }
}
