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

export class CPU {
  private memory: DataView // DataView for accessing memory
  private registerNames: Array<string> = [] // Array to store register names
  private registers: DataView // DataView to manage registers
  private registerMap: Record<string, number> // Mapping of register names to memory addresses
  private stackFrameSize: number = 0 // The internal stack frame size pointer

  constructor(memory: DataView) {
    this.memory = memory

    this.registerNames = [
      "ip", // Instruction pointer
      "acc", // Accumulator
      ...Array.from({ length: GENERIC_REGISTERS_COUNT }, (_, i) => `r${i + 1}`),
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

    // Set stack pointers to the very end of the memory
    // First -1 is because a 16bit value is 2 bytes long
    // Second -1 is because memory is zero-based
    this.setRegister("sp", memory.byteLength - 1 - 1)
    this.setRegister("fp", memory.byteLength - 1 - 1)
  }

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
   * Get the value of the specified register.
   * @param name - Register name
   * @returns The value stored in the register
   * @throws Error if the register name is invalid
   */
  getRegister(name: string): number {
    if (!(name in this.registerMap)) {
      throw new Error(`getRegister: No such register ${name}`)
    }

    return this.registers.getUint16(this.registerMap[name])
  }

  /**
   * Set the value of the specified register.
   * @param name - Register name
   * @param value - Value to set in the register
   * @throws Error if the register name is invalid
   */
  setRegister(name: string, value: number) {
    if (!(name in this.registerMap)) {
      throw new Error(`setRegister: No such register ${name}`)
    }

    return this.registers.setUint16(this.registerMap[name], value)
  }

  /**
   * Fetch the next instruction from memory and update the instruction pointer.
   * @returns The fetched instruction
   */
  fetch(): number {
    const nextInstructionAddress = this.getRegister("ip")
    const instruction = this.memory.getUint8(nextInstructionAddress)

    this.setRegister("ip", nextInstructionAddress + 1)

    return instruction
  }

  /**
   * Fetch the next 16-bit instruction from memory and update the instruction pointer.
   * @returns The fetched instruction
   */
  fetch16(): number {
    const nextInstructionAddress = this.getRegister("ip")
    const instruction = this.memory.getUint16(nextInstructionAddress)

    this.setRegister("ip", nextInstructionAddress + 2)

    return instruction
  }

  /**
   * Push a value onto the stack and then decrement stack pointer
   * @param value - Value to push
   */
  push(value: number) {
    const spAddress = this.getRegister("sp")

    this.memory.setUint16(spAddress, value)
    this.setRegister("sp", spAddress - 2)
    this.stackFrameSize += 2
  }

  /**
   * Push registers' state onto the stack
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
   * Pop a value from the stack and returns it
   * @returns The popped value
   */
  pop(): number {
    const nextSpAddress = this.getRegister("sp") + 2

    this.setRegister("sp", nextSpAddress)
    this.stackFrameSize -= 2

    return this.memory.getUint16(nextSpAddress)
  }

  /**
   * Fill registers with stacked state and reset stack pointers
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
   * Fetches the register index
   * @returns The fetched index
   */
  fetchRegisterIndex() {
    return (this.fetch() % this.registerNames.length) * 2
  }

  /**
   * Execute the specified instruction.
   * @param instruction - Instruction to execute
   */
  execute(instruction: number) {
    switch (instruction) {
      // Add value to register
      case MOV_LIT_REG: {
        const literal = this.fetch16()
        const register = this.fetchRegisterIndex()

        this.registers.setUint16(register, literal)
        return
      }
      // Move value between registers
      case MOV_REG_REG: {
        const registerFrom = this.fetchRegisterIndex()
        const registerTo = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerFrom)

        this.registers.setUint16(registerTo, value)
        return
      }
      // Move value from a register to a memory address
      case MOV_REG_MEM: {
        const registerFrom = this.fetchRegisterIndex()
        const address = this.fetch16()
        const value = this.registers.getUint16(registerFrom)

        this.memory.setUint16(address, value)
        return
      }
      // Move a value in memory to specified register
      case MOV_MEM_REG: {
        const address = this.fetch16()
        const registerTo = this.fetchRegisterIndex()
        const value = this.memory.getUint16(address)

        this.registers.setUint16(registerTo, value)
        return
      }
      // Add two values in specified registers and outputs in acc
      case ADD_REG_REG: {
        const r1 = this.fetch()
        const r2 = this.fetch()
        const registerValue1 = this.registers.getUint16(r1 * 2)
        const registerValue2 = this.registers.getUint16(r2 * 2)

        this.setRegister("acc", registerValue1 + registerValue2)
        return
      }
      // Jumps to specified address if value is not equal to acc
      case JMP_NOT_EQ: {
        const value = this.fetch16()
        const address = this.fetch16()

        if (value !== this.getRegister("acc")) {
          this.setRegister("ip", address)
        }

        return
      }
      // Push a value onto the stack
      case PSH_LIT: {
        const value = this.fetch16()

        this.push(value)
        return
      }
      // Push a register value onto the stack
      case PSH_REG: {
        const registerFrom = this.fetchRegisterIndex()
        const value = this.registers.getUint16(registerFrom)

        this.push(value)
        return
      }
      // Pop a value from the stack into a register
      case POP: {
        const registerIndex = this.fetchRegisterIndex()
        const value = this.pop()

        this.registers.setUint16(registerIndex, value)
        return
      }
      // Call a subroutine from a memory address
      case CAL_LIT: {
        const address = this.fetch16()

        this.pushState()
        this.setRegister("ip", address)
        return
      }
      // Call a subroutine from a register
      case CAL_REG: {
        const registerIndex = this.fetchRegisterIndex()
        const address = this.registers.getUint16(registerIndex)

        this.pushState()
        this.setRegister("ip", address)
        return
      }
      // Return from subroutine
      case RET: {
        this.popState()
        return
      }
    }
  }

  /**
   * Execute a single step: fetch an instruction and execute it.
   */
  step() {
    return this.execute(this.fetch())
  }
}
