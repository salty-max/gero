/**
 * @file CPU.ts
 *
 * This class emulates a 16-bit CPU, operating on an array of 16-bit values as
 * memory. It includes a stack and an instruction set.
 */

import {
  ADD_REG_REG,
  CAL_LIT,
  CAL_REG,
  JMP_NOT_EQ,
  MOV_LIT_REG,
  MOV_MEM_REG,
  MOV_REG_MEM,
  MOV_REG_REG,
  POP,
  PSH_LIT,
  PSH_REG,
  RET,
} from "./instructions"
import { logWithFormat } from "./logger"
import { createMemory } from "./memory"
import {
  ANSI_COLOR_BLUE,
  ANSI_COLOR_BOLD,
  ANSI_COLOR_GREEN,
  ANSI_COLOR_RESET,
} from "./util"

const GENERIC_REGISTERS_COUNT = 8

/**
 * Class that emulates a 16-bit CPU.
 */
export class CPU {
  /**
   * The memory of the CPU, represented as a DataView.
   * @private
   * @type {DataView}
   */
  private memory: DataView
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
   * @param {DataView} memory - The memory for the CPU.
   * @constructor
   */
  constructor(memory: DataView) {
    this.memory = memory

    this.registerNames = [
      "ip", // Instruction pointer
      "acc", // Accumulator
      ...Array.from({ length: GENERIC_REGISTERS_COUNT }, (_, i) => `r${i + 1}`), // Generic-purpose registers
      "sp", // Stack pointer
      "fp", // Stack frame pointer
    ]

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
     * The first subtraction is memory stores 16-bit values rather than bytes.
     * The second subtraction is because memory addresses are zero-based.
     */
    this.setRegister("sp", memory.byteLength - 1 - 1)
    this.setRegister("fp", memory.byteLength - 1 - 1)
  }

  /**
   * Method to print current register state for debugging purposes.
   */
  debug() {
    logWithFormat(
      "REGISTER\n----------------\n",
      ANSI_COLOR_BOLD,
      ANSI_COLOR_GREEN
    )

    this.registerNames.forEach((name) => {
      console.log(
        `${name}: ${ANSI_COLOR_BLUE}${ANSI_COLOR_BOLD}0x${this.getRegister(name)
          .toString(16)
          .padStart(4, "0")}${ANSI_COLOR_RESET}`
      )
    })
    console.log()
  }

  /**
   * Method to view the n bytes in memory starting from a specific address for debugging purposes.
   *
   * @param {number} address - The starting memory address.
   * @param {number} [n=8] - Number of bytes to display.
   */
  viewMemoryAt(address: number, n = 8) {
    const nextNBytes = Array.from({ length: n }, (_, i) => {
      return this.memory.getUint8(address + i)
    }).map((v) => `0x${v.toString(16).padStart(2, "0")}`)

    logWithFormat(
      "MEMORY AT\n----------------\n",
      ANSI_COLOR_BOLD,
      ANSI_COLOR_GREEN
    )
    console.log(
      `${ANSI_COLOR_BLUE}${ANSI_COLOR_BOLD}0x${address
        .toString(16)
        .padStart(4, "0")}${ANSI_COLOR_RESET}: ${nextNBytes.join(" ")}`
    )
  }

  /**
   * Method to retrieve the 16-bit value stored in a register by its name.
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
   * Method to store a 16-bit value into a register by its name.
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
   * Method to fetch the next 8-bit instruction from memory and increment the instruction pointer.
   *
   * @returns {number} - The fetched 8-bit instruction.
   */
  fetch(): number {
    const nextInstructionAddress = this.getRegister("ip")
    const instruction = this.memory.getUint8(nextInstructionAddress)

    this.setRegister("ip", nextInstructionAddress + 1)

    return instruction
  }

  /**
   * Method to fetch the next 16-bit instruction (or a data word) from memory and increment the instruction pointer.
   *
   * @returns {number} - The fetched 16-bit instruction or data word.
   */
  fetch16(): number {
    const nextInstructionAddress = this.getRegister("ip")
    const instruction = this.memory.getUint16(nextInstructionAddress)

    this.setRegister("ip", nextInstructionAddress + 2)

    return instruction
  }

  /**
   * Method to push a 16-bit value onto the stack and decrement the stack pointer.
   *
   * @param {number} value - The 16-bit value to push onto the stack.
   */
  push(value: number) {
    const spAddress = this.getRegister("sp")

    this.memory.setUint16(spAddress, value)
    this.setRegister("sp", spAddress - 2)
    this.stackFrameSize += 2
  }

  /**
   * Method to save the current CPU state (registers and return address) onto the stack.
   */
  pushState() {
    // Push generic registers' current state onto the stack
    for (let i = 1; i <= GENERIC_REGISTERS_COUNT; i++) {
      this.push(this.getRegister(`r${i}`))
    }
    // Push instruction pointer onto the stack as a return address for the subroutine
    this.push(this.getRegister("ip"))
    // Push current stack frame size + 2 bytes for this pointer
    this.push(this.stackFrameSize + 2)

    // Set frame pointer to current stack pointer
    this.setRegister("fp", this.getRegister("sp"))
    // Reset stack frame size pointer to allow another subroutine to use it
    this.stackFrameSize = 0
  }

  /**
   * Method to pop a 16-bit value from the stack and increment the stack pointer.
   *
   * @returns {number} - The popped 16-bit value.
   */
  pop(): number {
    const nextSpAddress = this.getRegister("sp") + 2

    this.setRegister("sp", nextSpAddress)
    this.stackFrameSize -= 2

    return this.memory.getUint16(nextSpAddress)
  }

  /**
   * Method to restore the CPU state (registers and return address) from the stack.
   */
  popState() {
    const framePointerAddress = this.getRegister("fp")
    this.setRegister("sp", framePointerAddress)
    this.stackFrameSize = this.pop()
    const currentStackFrameSize = this.stackFrameSize

    this.setRegister("ip", this.pop())
    for (let i = GENERIC_REGISTERS_COUNT; i >= 1; i--) {
      this.setRegister(`r${i}`, this.pop())
    }

    const nArgs = this.pop()
    for (let i = 0; i < nArgs; i++) {
      this.pop()
    }
    this.setRegister("fp", framePointerAddress + currentStackFrameSize)
  }

  /**
   * Method to fetch the next byte from memory, interpret it as a register index, and return it.
   *
   * @returns {number} - The fetched register index.
   */
  fetchRegisterIndex() {
    return (this.fetch() % this.registerNames.length) * 2
  }

  /**
   * Method to execute a given instruction.
   *
   * @param {number} instruction - The opcode of the instruction to execute.
   */
  execute(instruction: number) {
    switch (instruction) {
      /**
       * Move Literal to Register (MOV_LIT_REG) operation.
       * Fetches a literal 16-bit value and a register index from the instruction stream,
       * and then sets the fetched literal value into the specified register.
       */
      case MOV_LIT_REG: {
        const literal = this.fetch16()
        const register = this.fetchRegisterIndex()

        this.registers.setUint16(register, literal)
        return
      }
      /**
       * Move Register to Register (MOV_REG_REG) operation.
       * Fetches two register indexes from the instruction stream,
       * reads the value from the first (source) register,
       * and then sets that value into the second (destination) register.
       */
      case MOV_REG_REG: {
        const registerFrom = this.fetchRegisterIndex()
        const registerTo = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerFrom)

        this.registers.setUint16(registerTo, value)
        return
      }
      /**
       * Move Register to Memory (MOV_REG_MEM) operation.
       * Fetches a register index and a memory address from the instruction stream,
       * reads the value from the specified register,
       * and then sets that value into the specified memory address.
       */
      case MOV_REG_MEM: {
        const registerFrom = this.fetchRegisterIndex()
        const address = this.fetch16()
        const value = this.registers.getUint16(registerFrom)

        this.memory.setUint16(address, value)
        return
      }
      /**
       * Move Memory to Register (MOV_MEM_REG) operation.
       * Fetches a memory address and a register index from the instruction stream,
       * reads the value from the specified memory address,
       * and then sets that value into the specified register.
       */
      case MOV_MEM_REG: {
        const address = this.fetch16()
        const registerTo = this.fetchRegisterIndex()
        const value = this.memory.getUint16(address)

        this.registers.setUint16(registerTo, value)
        return
      }
      /**
       * Add Register to Register (ADD_REG_REG) operation.
       * Fetches two register indexes from the instruction stream,
       * reads the values from the two registers,
       * adds these values, and then stores the result into the accumulator (acc) register.
       */
      case ADD_REG_REG: {
        const r1 = this.fetch()
        const r2 = this.fetch()
        const registerValue1 = this.registers.getUint16(r1 * 2)
        const registerValue2 = this.registers.getUint16(r2 * 2)

        this.setRegister("acc", registerValue1 + registerValue2)
        return
      }
      /**
       * Jump if Not Equal (JMP_NOT_EQ) operation.
       * Fetches a literal 16-bit value and a memory address from the instruction stream,
       * then compares the fetched value with the value in the accumulator (acc) register.
       * If the values are not equal, it sets the instruction pointer (ip) register to the fetched memory address,
       * effectively causing a jump to a new location in the instruction stream.
       */
      case JMP_NOT_EQ: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value !== this.getRegister("acc")) {
          this.setRegister("ip", address)
        }

        return
      }
      /**
       * Push Literal (PSH_LIT) operation.
       * Fetches a literal 16-bit value from the instruction stream,
       * and then pushes it onto the stack.
       */
      case PSH_LIT: {
        const value = this.fetch16()

        this.push(value)
        return
      }
      /**
       * Push Register (PSH_REG) operation.
       * Fetches a register index from the instruction stream,
       * reads the value from the specified register,
       * and then pushes it onto the stack.
       */
      case PSH_REG: {
        const registerFrom = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerFrom)

        this.push(value)
        return
      }
      /**
       * Pop to Register (POP) operation.
       * Fetches a register index from the instruction stream,
       * pops a value from the stack,
       * and then sets the popped value into the specified register.
       */
      case POP: {
        const registerIndex = this.fetchRegisterIndex()
        const value = this.pop()

        this.registers.setUint16(registerIndex, value)
        return
      }
      /**
       * Call Literal (CAL_LIT) operation.
       * Fetches a memory address from the instruction stream,
       * pushes the current state onto the stack (for returning later),
       * and then sets the instruction pointer (ip) register to the fetched memory address,
       * effectively causing a jump to a new location in the instruction stream.
       */
      case CAL_LIT: {
        const address = this.fetch16()

        this.pushState()
        this.setRegister("ip", address)
        return
      }
      /**
       * Call Register (CAL_REG) operation.
       * Fetches a register index from the instruction stream,
       * reads a memory address from the specified register,
       * pushes the current state onto the stack (for returning later),
       * and then sets the instruction pointer (ip) register to the read memory address,
       * effectively causing a jump to a new location in the instruction stream.
       */
      case CAL_REG: {
        const registerIndex = this.fetchRegisterIndex()
        const address = this.registers.getUint16(registerIndex)

        this.pushState()
        this.setRegister("ip", address)
        return
      }
      /**
       * Return (RET) operation.
       * Pops the previously pushed state from the stack,
       * effectively causing a jump back to the location in the instruction stream from where the subroutine was called.
       */
      case RET: {
        this.popState()
        return
      }
    }
  }

  /**
   * Method to execute a single step: fetch the next instruction and execute it.
   */
  step() {
    this.execute(this.fetch())
  }
}
