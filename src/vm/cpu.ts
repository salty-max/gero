/**
 * @file CPU.ts
 *
 * This class emulates a 16-bit CPU, operating on an array of 16-bit values as
 * memory. It includes a stack and an instruction set.
 *
 * @see CPU
 */

import I from '../instructions'
import { Memory, createRAM } from './memory'
import { MemoryMapper } from './memory-mapper'
import { GENERIC_REGISTERS_COUNT, REGISTER_NAMES } from '../util/register'
import instructions from '../instructions'

const opcodeToName = (instruction: number) => {
  const ins = Object.values(instructions).find((i) => i.opcode === instruction)
  return ins?.instruction
}

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
  private registers: Memory
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
  private stackFrameSize: number
  /**
   * @private
   * @type {number}
   * The memory address at which the interrupt vector table starts.
   */
  private interruptVectorAddress: number
  /**
   * @private
   * @type {boolean}
   * Indicates whether the CPU is currently in an interrupt handler.
   * This is used for managing interrupts.
   */
  private isInInterruptHandler: boolean
  /**
   * @private
   * @type {boolean}
   * Indicates whether the CPU is currently paused.
   */
  private isPaused: boolean
  /**
   * @private
   * @type {boolean}
   * Indicates whether the CPU is currently in debug mode.
   */
  private isDebugMode: boolean

  /**
   * Constructor for the CPU class.
   * @param {MemoryMapper} memory - The memory for the CPU.
   * @constructor
   */
  constructor(memory: MemoryMapper, interruptVectorAddress = 0x1000) {
    this.memory = memory

    this.isPaused = false
    this.registers = createRAM(REGISTER_NAMES.length * 2) // Create DataView for registers
    this.registerMap = REGISTER_NAMES.reduce(
      (map: Record<string, number>, name: string, i: number) => {
        map[name] = i * 2 // Assign memory address to each register
        return map
      },
      {}
    )

    // Set the starting address of the interrupt vector table.
    this.interruptVectorAddress = interruptVectorAddress

    // Initialize the instruction pointer (ip) register.
    this.setRegister('ip', this.memory.getUint16(this.interruptVectorAddress))

    // Initialize the flag register (f) to 0.
    this.isInInterruptHandler = false

    // Initialize the interrupt mask (im) register.
    // By setting it to 0xffff, all interrupts are unmasked and hence enabled by default.
    this.setRegister('im', 0xffff)

    /**
     * Initialize the "sp" (stack pointer) and "fp" (frame pointer) registers.
     * These pointers are set to point to the very end of the memory to initiate an empty stack,
     * which grows towards decreasing memory addresses.
     * They are initialized at 0xffff - 1 (0xfffe).
     */
    this.setRegister('sp', 0xffff - 1)
    this.setRegister('fp', 0xffff - 1)

    // Initialize the stack frame size pointer.
    this.stackFrameSize = 0

    this.isDebugMode = false
  }

  setDebugMode(mode: boolean) {
    this.isDebugMode = mode
  }

  /**
   * Prints current register state for debugging purposes.
   */
  debug() {
    let debugStr = ''
    REGISTER_NAMES.forEach((name, i) => {
      debugStr += `${name}:\t0x${this.getRegister(name)
        .toString(16)
        .padStart(4, '0')}\t`
      if (i > 0 && i % 4 === 0) {
        debugStr += '\n'
      }
    })
    console.log(debugStr + '\n')
  }

  /**
   * Prints the n bytes in memory starting from a specific address for debugging purposes.
   *
   * @param {number} address - The starting memory address.
   * @param {number} [n=8] - Number of bytes to display.
   */
  viewMemoryAt(address: number, n = 8) {
    // 0x0f01: 0x04 0x05 0xA3 0xFE 0x13 0x0D 0x44 0x0F ...
    const nextNBytes = Array.from({ length: n }, (_, i) =>
      this.memory.getUint8(address + i)
    ).map((v) => `0x${v.toString(16).padStart(2, '0')}`)

    console.log(
      `memory @ 0x${address.toString(16).padStart(4, '0')}: ${nextNBytes.join(
        ' '
      )}`
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
  private fetch(noIncrement = false): number {
    const nextInstructionAddress = this.getRegister('ip')
    const instruction = this.memory.getUint8(nextInstructionAddress)

    if (noIncrement === false) {
      this.setRegister('ip', nextInstructionAddress + 1)
    }

    return instruction
  }

  /**
   * Fetches the next 16-bit instruction (or a data word) from memory and increment the instruction pointer.
   * @private
   * @returns {number} - The fetched 16-bit instruction or data word.
   */
  private fetch16(noIncrement = false): number {
    const nextInstructionAddress = this.getRegister('ip')
    const instruction = this.memory.getUint16(nextInstructionAddress)

    if (noIncrement === false) {
      this.setRegister('ip', nextInstructionAddress + 2)
    }

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
    //return (this.fetch() % REGISTER_NAMES.length) * 2
    return this.fetch() * 2
  }

  /**
   * Handles interrupts by verifying their 'mask' and if they are unmasked,
   * it retrieves the address of the interrupt from the interrupt vector and sets the Instruction Pointer (IP) to that address.
   * @param {number} value - The interrupt number that is to be handled.
   * @returns {boolean} Returns false if the interrupt is masked, otherwise it does not return a value.
   */
  handleInterrupt(value: number) {
    // Calculate the interrupt vector index,
    // this is necessary to ensure the interrupt value does not exceed the size of the interrupt vector (15).
    const interruptBit = value % 0xf

    // Check if the interrupt is unmasked.
    // The operation '1 << interruptBit' generates a number with only one bit set at the position corresponding to the interruptBit.
    // Bitwise AND operation '&' with the interrupt mask determines if the interrupt is unmasked.
    const isUnmasked = Boolean((1 << interruptBit) & this.getRegister('im'))
    // If interrupt is masked, return false
    if (!isUnmasked) {
      return false
    }

    // Calculate the address pointer in the interrupt vector.
    // The interrupt vector is a table that contains addresses of interrupt handlers.
    // Each entry takes 2 bytes, so we multiply the index by 2 to get the correct address in the interrupt vector.
    const addressPtr = this.interruptVectorAddress + interruptBit * 2
    // Get the address of the interrupt handler from the interrupt vector by reading 2 bytes (16 bits) from the memory.
    const address = this.memory.getUint16(addressPtr)

    // Check if we are not already in an interrupt handler
    if (!this.isInInterruptHandler) {
      // Push 0 for the number of arguments. This is done to comply with the calling convention.
      // This value will be popped off the stack inside the interrupt handler.
      this.push(this.getRegister('ip'))
    }

    // Set the flag to indicate we are in an interrupt handler. This prevents nested interrupt handling.
    this.isInInterruptHandler = true
    // Set the instruction pointer to the interrupt handler address, which effectively transfers control to the interrupt handler.
    this.setRegister('ip', address)
  }

  /**
   * Executes a given instruction.
   * @private
   * @param {number} instruction - The opcode of the instruction to execute.
   * @returns {boolean} Whether the computation should stop
   */
  private execute(instruction: number): boolean | undefined {
    if (this.isDebugMode) {
      console.log('Current: ' + opcodeToName(instruction))
    }

    try {
      switch (instruction) {
        /**
         * Move 8-bit Literal to Register (MOV8_LIT_REG) instruction.
         * Fetches a literal 8-bit value and a register index from the instruction stream,
         * and then sets the fetched literal value into the specified memory address.
         */
        case I.MOV8_LIT_MEM.opcode: {
          const value = this.fetch()
          const address = this.fetch16()
          this.memory.setUint8(address, value)
          return
        }
        /**
         * Move 8-bit value from memory at specified address to Register (MOV8_MEM_REG) instruction.
         * Fetches a memory address and a register index from the instruction stream,
         * reads the value from the specified memory address,
         * and then sets that value into the specified register.
         */
        case I.MOV8_MEM_REG.opcode: {
          const address = this.fetch16()
          const reg = this.fetchRegisterIndex()
          const value = this.memory.getUint8(address)
          this.registers.setUint16(reg, value)
          return
        }
        /**
         * Move 8-bit value from Register to Memory (MOV8_REG_MEM) instruction.
         * Fetches a register index and a memory address from the instruction stream,
         * reads the value from the specified register,
         * and then sets that value into the specified memory address.
         */
        case I.MOVL_REG_MEM.opcode: {
          const registerFrom = this.fetchRegisterIndex()
          const address = this.fetch16()
          const value = this.registers.getUint16(registerFrom) & 0xff
          this.memory.setUint8(address, value)
          return
        }
        /**
         * Move 8-bit value from Register to Memory (MOV8_REG_MEM) instruction.
         * Fetches a register index and a memory address from the instruction stream,
         * reads the value from the specified register,
         * and then sets that value into the specified memory address.
         */
        case I.MOVH_REG_MEM.opcode: {
          const registerFrom = this.fetchRegisterIndex()
          const address = this.fetch16()
          const value = this.registers.getUint8(registerFrom)
          this.memory.setUint8(address, value)
          return
        }
        /**
         * Move 8-bit Register* to Register (MOV8_REG_PTR_REG) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads a memory address from the first (source) register (treats it as a pointer),
         * fetches the value from the fetched memory address,
         * and then sets that value into the second (destination) register.
         */
        case I.MOV8_REG_PTR_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const ptr = this.registers.getUint16(r1)
          const value = this.memory.getUint8(ptr)
          this.registers.setUint16(r2, value)
          return
        }
        /**
         * Move 8-bit from Register to Register* (MOV8_REG_REG_PTR) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads a memory address from the second (destination) register (treats it as a pointer),
         * fetches the value from the first (source) register,
         * and then sets that value into the fetched memory address.
         */
        case I.MOV8_REG_REG_PTR.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const value = this.registers.getUint16(r1) & 0xff
          const addr = this.registers.getUint16(r2)
          this.memory.setUint8(addr, value)
          return
        }
        /**
         * Move Literal to Register (MOV_LIT_REG) instruction.
         * Fetches a literal 16-bit value and a register index from the instruction stream,
         * and then sets the fetched literal value into the specified register.
         */
        case I.MOV_LIT_REG.opcode: {
          const literal = this.fetch16()
          const register = this.fetchRegisterIndex()

          this.registers.setUint16(register, literal)
          return
        }
        /**
         * Move Register to Register (MOV_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads the value from the first (source) register,
         * and then sets that value into the second (destination) register.
         */
        case I.MOV_REG_REG.opcode: {
          const registerFrom = this.fetchRegisterIndex()
          const registerTo = this.fetchRegisterIndex()
          const value = this.registers.getUint16(registerFrom)

          this.registers.setUint16(registerTo, value)
          return
        }
        /**
         * Move Register to Memory (MOV_REG_MEM) instruction.
         * Fetches a register index and a memory address from the instruction stream,
         * reads the value from the specified register,
         * and then sets that value into the specified memory address.
         */
        case I.MOV_REG_MEM.opcode: {
          const registerFrom = this.fetchRegisterIndex()
          const address = this.fetch16()
          const value = this.registers.getUint16(registerFrom)

          this.memory.setUint16(address, value)
          return
        }
        /**
         * Move Memory to Register (MOV_MEM_REG) instruction.
         * Fetches a memory address and a register index from the instruction stream,
         * reads the value from the specified memory address,
         * and then sets that value into the specified register.
         */
        case I.MOV_MEM_REG.opcode: {
          const address = this.fetch16()
          const registerTo = this.fetchRegisterIndex()
          const value = this.memory.getUint16(address)

          this.registers.setUint16(registerTo, value)
          return
        }
        /**
         * Move Literal to Memory (MOV_LIT_MEM) instruction.
         * Fetches a literal 16-bit value and a memory address from the instruction stream,
         * and then sets the fetched literal value into the specified memory address.
         */
        case I.MOV_LIT_MEM.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          this.memory.setUint16(address, value)
          return
        }
        /**
         * Move Register* to Register (MOV_REG_PTR_REG) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads a memory address from the first (source) register (treats it as a pointer),
         * fetches the value from the fetched memory address,
         * and then sets that value into the second (destination) register.
         */
        case I.MOV_REG_PTR_REG.opcode: {
          const registerFrom = this.fetchRegisterIndex()
          const registerTo = this.fetchRegisterIndex()
          const ptr = this.registers.getUint16(registerFrom)
          const value = this.memory.getUint16(ptr)

          this.registers.setUint16(registerTo, value)
          return
        }
        /**
         * Move value from Register to Register* (MOV_REG_REG_PTR) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads a memory address from the second (destination) register (treats it as a pointer),
         * fetches the value from the first (source) register,
         * and then sets that value into the fetched memory address.
         */
        case I.MOV_REG_REG_PTR.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const value = this.registers.getUint16(r1)
          const addr = this.registers.getUint16(r2)
          this.memory.setUint16(addr, value)
          return
        }
        /**
         * Move Literal Offset to Register (MOV_LIT_OFF_REG) instruction.
         * Fetches a base memory address and two register indexes from the instruction stream,
         * reads an offset from the first (source) register,
         * fetches the value from the memory address calculated by adding the offset to the base address,
         * and then sets that value into the second (destination) register.
         */
        case I.MOV_LIT_OFF_REG.opcode: {
          const baseAddress = this.fetch16()
          const registerFrom = this.fetchRegisterIndex()
          const registerTo = this.fetchRegisterIndex()
          const offset = this.registers.getUint16(registerFrom)
          const value = this.memory.getUint16(baseAddress + offset)

          this.registers.setUint16(registerTo, value)
          return
        }
        /**
         * Add Register to Register (ADD_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads the values from the two registers,
         * adds these values, and then stores the result into the accumulator (acu) register.
         */
        case I.ADD_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const registerValue1 = this.registers.getUint16(r1)
          const registerValue2 = this.registers.getUint16(r2)

          this.setRegister('acu', registerValue1 + registerValue2)
          return
        }
        /**
         * Add Literal to Register (ADD_LIT_REG) instruction.
         * Fetches a literal 16-bit value and a register index from the instruction stream,
         * reads the value from the fetched register,
         * adds the literal to the fetched value, and then stores the result in the accumulator (acu) register.
         */
        case I.ADD_LIT_REG.opcode: {
          const literal = this.fetch16()
          const registerIndex = this.fetchRegisterIndex()
          const value = this.registers.getUint16(registerIndex)

          this.setRegister('acu', literal + value)
          return
        }
        /**
         * Subtract Literal from Register (SUB_LIT_REG) instruction.
         * Fetches a literal 16-bit value and a register index from the instruction stream,
         * reads the value from the fetched register,
         * subtracts the fetched value from the literal, and then stores the result in the accumulator (acu) register.
         */
        case I.SUB_LIT_REG.opcode: {
          const literal = this.fetch16()
          const registerIndex = this.fetchRegisterIndex()
          const value = this.registers.getUint16(registerIndex)

          this.setRegister('acu', literal - value)
          return
        }
        /**
         * Subtract Literal from Register (SUB_REG_LIT) instruction.
         * Fetches a register index and a literal 16-bit value from the instruction stream,
         * reads the value from the fetched register,
         * subtracts the literal from the fetched value, and then stores the result in the accumulator (acu) register.
         */
        case I.SUB_REG_LIT.opcode: {
          const registerIndex = this.fetchRegisterIndex()
          const literal = this.fetch16()
          const value = this.registers.getUint16(registerIndex)

          this.setRegister('acu', value - literal)
          return
        }
        /**
         * Subtract Register from Register (SUB_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads the values from the two registers,
         * subtracts the second value from the first one, and then stores the result in the accumulator (acu) register.
         */
        case I.SUB_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const r1Value = this.registers.getUint16(r1)
          const r2Value = this.registers.getUint16(r2)

          this.setRegister('acu', r1Value - r2Value)
          return
        }
        /**
         * Multiply Literal with Register (MUL_LIT_REG) instruction.
         * Fetches a literal 16-bit value and a register index from the instruction stream,
         * reads the value from the fetched register,
         * multiplies the literal with the fetched value, and then stores the result in the accumulator (acu) register.
         */
        case I.MUL_LIT_REG.opcode: {
          const literal = this.fetch16()
          const registerIndex = this.fetchRegisterIndex()
          const value = this.registers.getUint16(registerIndex)

          const res = literal * value
          this.setRegister('acu', res)
          return
        }
        /**
         * Multiply Register with Register (MUL_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream,
         * reads the values from the two registers,
         * multiplies the two values, and then stores the result in the accumulator (acu) register.
         */
        case I.MUL_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const r1Value = this.registers.getUint16(r1)
          const r2Value = this.registers.getUint16(r2)

          const res = r1Value * r2Value
          this.setRegister('acu', res)
          return
        }
        /**
         * Increment Register (INC_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the fetched register,
         * increments the fetched value, and then stores the result back into the register.
         */
        case I.INC_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const value = this.registers.getUint16(r)

          this.registers.setUint16(r, value + 1)
          return
        }
        /**
         * Decrement Register (DEC_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the fetched register,
         * decrements the fetched value, and then stores the result back into the register.
         */
        case I.DEC_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const value = this.registers.getUint16(r)

          this.registers.setUint16(r, value - 1)
          return
        }
        /**
         * Decrement Register (DEC_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the fetched register,
         * decrements the fetched value, and then stores the result back into the register.
         */
        case I.NEG_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const value = this.registers.getUint16(r)

          this.registers.setUint16(r, (~value & 0xffff) + 1)
          return
        }
        /**
         * Left Shift Register by Literal (LSF_REG_LIT) instruction.
         * Fetches a register index and a literal value from the instruction stream.
         * Left shifts the value in the register by the specified literal value,
         * and then stores the result back into the register.
         */
        case I.LSF_REG_LIT.opcode: {
          const r = this.fetchRegisterIndex()
          const literal = this.fetch()
          const rValue = this.registers.getUint16(r)

          this.registers.setUint16(r, rValue << literal)
          return
        }
        /**
         * Left Shift Register by Register (LSF_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream.
         * Left shifts the value in the first register by the value in the second register,
         * and then stores the result back into the first register.
         */
        case I.LSF_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const v1 = this.registers.getUint16(r1)
          const v2 = this.registers.getUint16(r2)

          this.registers.setUint16(r1, v1 << v2)
          return
        }
        /**
         * Right Shift Register by Literal (RSF_REG_LIT) instruction.
         * Fetches a register index and a literal value from the instruction stream.
         * Right shifts the value in the register by the specified literal value,
         * and then stores the result back into the register.
         */
        case I.RSF_REG_LIT.opcode: {
          const r = this.fetchRegisterIndex()
          const literal = this.fetch()
          const rValue = this.registers.getUint16(r)

          this.registers.setUint16(r, rValue >> literal)
          return
        }
        /**
         * Right Shift Register by Register (RSF_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream.
         * Right shifts the value in the first register by the value in the second register,
         * and then stores the result back into the first register.
         */
        case I.RSF_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const v1 = this.registers.getUint16(r1)
          const v2 = this.registers.getUint16(r2)

          this.registers.setUint16(r1, v1 >> v2)
          return
        }
        /**
         * Bitwise AND Register with Literal (AND_REG_LIT) instruction.
         * Fetches a register index and a literal value from the instruction stream.
         * Performs a bitwise AND operation between the value in the register and the literal value,
         * and then stores the result in the accumulator (acu) register.
         */

        case I.AND_REG_LIT.opcode: {
          const r = this.fetchRegisterIndex()
          const literal = this.fetch()
          const rValue = this.registers.getUint16(r)

          const res = rValue & literal
          this.setRegister('acu', res)
          return
        }
        /**
         * Bitwise AND Register with Register (AND_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream.
         * Performs a bitwise AND operation between the values in the two registers,
         * and then stores the result in the accumulator (acu) register.
         */
        case I.AND_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const v1 = this.registers.getUint16(r1)
          const v2 = this.registers.getUint16(r2)

          const res = v1 & v2
          this.setRegister('acu', res)
          return
        }
        /**
         * Bitwise OR Register with Literal (OR_REG_LIT) instruction.
         * Fetches a register index and a literal value from the instruction stream.
         * Performs a bitwise OR operation between the value in the register and the literal value,
         * and then stores the result in the accumulator (acu) register.
         */
        case I.OR_REG_LIT.opcode: {
          const r = this.fetchRegisterIndex()
          const literal = this.fetch()
          const rValue = this.registers.getUint16(r)

          const res = rValue | literal
          this.setRegister('acu', res)
          return
        }
        /**
         * Bitwise OR Register with Register (OR_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream.
         * Performs a bitwise OR operation between the values in the two registers,
         * and then stores the result in the accumulator (acu) register.
         */
        case I.OR_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const v1 = this.registers.getUint16(r1)
          const v2 = this.registers.getUint16(r2)

          const res = v1 | v2
          this.setRegister('acu', res)
          return
        }
        /**
         * Bitwise XOR Register with Literal (XOR_REG_LIT) instruction.
         * Fetches a register index and a literal value from the instruction stream.
         * Performs a bitwise XOR operation between the value in the register and the literal value,
         * and then stores the result in the accumulator (acu) register.
         */
        case I.XOR_REG_LIT.opcode: {
          const r = this.fetchRegisterIndex()
          const literal = this.fetch()
          const rValue = this.registers.getUint16(r)

          const res = rValue ^ literal
          this.setRegister('acu', res)
          return
        }
        /**
         * Bitwise XOR Register with Register (XOR_REG_REG) instruction.
         * Fetches two register indexes from the instruction stream.
         * Performs a bitwise XOR operation between the values in the two registers,
         * and then stores the result in the accumulator (acu) register.
         */
        case I.XOR_REG_REG.opcode: {
          const r1 = this.fetchRegisterIndex()
          const r2 = this.fetchRegisterIndex()
          const v1 = this.registers.getUint16(r1)
          const v2 = this.registers.getUint16(r2)

          const res = v1 ^ v2
          this.setRegister('acu', res)
          return
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
         * The final result is stored in the accumulator (acu) register.
         */
        case I.NOT.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)

          const res = ~v & 0xffff
          this.setRegister('acu', res)
          return
        }
        /**
         * Jump if Not Equal (JNE_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register (v),
         * fetches a memory address (address),
         * and compares the value in the register with the accumulator (acu) register.
         * If the values are not equal, the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JNE_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)
          const address = this.fetch16()

          if (v !== this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Not Equal (JNE_LIT) instruction.
         * Fetches a literal 16-bit value and a memory address from the instruction stream,
         * then compares the fetched value with the value in the accumulator (acu) register.
         * If the values are not equal, it sets the instruction pointer (ip) register to the fetched memory address,
         * effectively causing a jump to a new location in the instruction stream.
         */
        case I.JNE_LIT.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          if (value !== this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Equal (JEQ_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register (v),
         * fetches a memory address (address),
         * and compares the value in the register with the accumulator (acu) register.
         * If the values are equal, the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JEQ_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)
          const address = this.fetch16()

          if (v === this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Equal (JEQ_LIT) instruction.
         * Fetches a literal 16-bit value (value),
         * fetches a memory address (address),
         * and compares the literal value with the accumulator (acu) register.
         * If the values are equal, the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JEQ_LIT.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          if (value === this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Less Than (JLT_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register (v),
         * fetches a memory address (address),
         * and compares the value in the register with the accumulator (acu) register.
         * If the value in the register is less than the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JLT_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)
          const address = this.fetch16()

          if (v < this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Less Than (JLT_LIT) instruction.
         * Fetches a literal 16-bit value (value),
         * fetches a memory address (address),
         * and compares the literal value with the accumulator (acu) register.
         * If the literal value is less than the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JLT_LIT.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          if (value < this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Greater Than (JGT_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register (v),
         * fetches a memory address (address),
         * and compares the value in the register with the accumulator (acu) register.
         * If the value in the register is greater than the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JGT_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)
          const address = this.fetch16()

          if (v > this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Greater Than (JGT_LIT) instruction.
         * Fetches a literal 16-bit value (value),
         * fetches a memory address (address),
         * and compares the literal value with the accumulator (acu) register.
         * If the literal value is greater than the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JGT_LIT.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          if (value > this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Less Than or Equal (JLE_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register (v),
         * fetches a memory address (address),
         * and compares the value in the register with the accumulator (acu) register.
         * If the value in the register is less than or equal to the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JLE_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)
          const address = this.fetch16()

          if (v <= this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Less Than or Equal (JLE_LIT) instruction.
         * Fetches a literal 16-bit value (value),
         * fetches a memory address (address),
         * and compares the literal value with the accumulator (acu) register.
         * If the literal value is less than or equal to the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JLE_LIT.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          if (value <= this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Greater Than or Equal (JGE_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register (v),
         * fetches a memory address (address),
         * and compares the value in the register with the accumulator (acu) register.
         * If the value in the register is greater than or equal to the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JGE_REG.opcode: {
          const r = this.fetchRegisterIndex()
          const v = this.registers.getUint16(r)
          const address = this.fetch16()

          if (v >= this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump if Greater Than or Equal (JGE_LIT) instruction.
         * Fetches a literal 16-bit value (value),
         * fetches a memory address (address),
         * and compares the literal value with the accumulator (acu) register.
         * If the literal value is greater than or equal to the value in the accumulator,
         * the instruction pointer (ip) register is set to the fetched memory address,
         * causing a jump to a new location in the instruction stream.
         */
        case I.JGE_LIT.opcode: {
          const value = this.fetch16()
          const address = this.fetch16()

          if (value >= this.getRegister('acu')) {
            this.setRegister('ip', address)
          }

          return
        }
        /**
         * Jump Literal (JMP_LIT) instruction.
         * Fetches a memory address from the instruction stream,
         * and then sets the instruction pointer (ip) register to the fetched memory address,
         */
        case I.JMP_LIT.opcode: {
          const address = this.fetch16()
          this.setRegister('ip', address)
          return
        }
        /**
         * Jump Literal (JMP_LIT) instruction.
         * Fetches a memory address from the instruction stream,
         * and then sets the instruction pointer (ip) register to the fetched memory address,
         */
        case I.JMP_REG.opcode: {
          const reg = this.fetchRegisterIndex()
          const addr = this.registers.getUint16(reg)
          this.setRegister('ip', addr)
          return
        }
        /**
         * Push Literal (PSH_LIT) instruction.
         * Fetches a literal 16-bit value from the instruction stream,
         * and then pushes it onto the stack.
         */
        case I.PSH_LIT.opcode: {
          const value = this.fetch16()
          this.push(value)
          return
        }
        /**
         * Push Register (PSH_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads the value from the specified register,
         * and then pushes it onto the stack.
         */
        case I.PSH_REG.opcode: {
          const registerFrom = this.fetchRegisterIndex()
          const value = this.registers.getUint16(registerFrom)
          this.push(value)
          return
        }
        /**
         * Pop to Register (POP) instruction.
         * Fetches a register index from the instruction stream,
         * pops a value from the stack,
         * and then sets the popped value into the specified register.
         */
        case I.POP.opcode: {
          const registerIndex = this.fetchRegisterIndex()
          const value = this.pop()
          this.registers.setUint16(registerIndex, value)
          return
        }
        /**
         * Call Literal (CAL_LIT) instruction.
         * Fetches a memory address from the instruction stream,
         * pushes the current state onto the stack (for returning later),
         * and then sets the instruction pointer (ip) register to the fetched memory address,
         * effectively causing a jump to a new location in the instruction stream.
         */
        case I.CAL_LIT.opcode: {
          const address = this.fetch16()
          this.pushState()
          this.setRegister('ip', address)
          return
        }
        /**
         * Call Register (CAL_REG) instruction.
         * Fetches a register index from the instruction stream,
         * reads a memory address from the specified register,
         * pushes the current state onto the stack (for returning later),
         * and then sets the instruction pointer (ip) register to the read memory address,
         * effectively causing a jump to a new location in the instruction stream.
         */
        case I.CAL_REG.opcode: {
          const registerIndex = this.fetchRegisterIndex()
          const address = this.registers.getUint16(registerIndex)
          this.pushState()
          this.setRegister('ip', address)
          return
        }
        /**
         * Return (RET) instruction.
         * Pops the previously pushed state from the stack,
         * effectively causing a jump back to the location in the instruction stream from where the subroutine was called.
         */
        case I.RET.opcode: {
          this.popState()
          return
        }
        /**
         * Interrupt (INT) instruction.
         * Triggers a software interrupt.
         */
        case I.INT.opcode: {
          const interruptValue = this.fetch16() & 0xf
          this.handleInterrupt(interruptValue)
          return
        }
        /**
         * Return from Interrupt (RTI) instruction.
         * Returns from an interrupt handler
         */
        case I.RET_INT.opcode: {
          this.isInInterruptHandler = false
          this.setRegister('ip', this.pop())
          return
        }
        /**
         * Break (BRK) instruction.
         * Triggers a breakpoint.
         */
        case I.BRK.opcode: {
          this.debug()
          // eslint-disable-next-line no-debugger
          debugger
          return
        }
        /**
         * Halt (HLT) instruction.
         * Tells the CPU to stop all computation.
         */
        case I.HLT.opcode:
          return true
      }
    } catch (err) {
      const ins = Object.values(instructions).find(
        (i) => i.opcode === instruction
      )
      console.group()
      console.error('Crash', err)
      console.error(`IP: 0x${this.getRegister('ip').toString(16)}`)
      console.error(`Instruction: ${ins?.instruction}`)
      this.viewMemoryAt(this.getRegister('ip'))
      this.debug()
      console.groupEnd()
      // eslint-disable-next-line no-debugger
      debugger
    }
  }

  /**
   * Executes a single step: fetch the next instruction and execute it.
   */
  step() {
    const instruction = this.fetch()
    const retVal = this.execute(instruction)
    if (this.isDebugMode) {
      this.debug()
      const next = this.fetch(true /* noIncrement */)
      console.log(`Next: ${opcodeToName(next)}`)
    }

    return retVal
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
