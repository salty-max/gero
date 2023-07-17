import { CPU } from "../src/cpu"
import {
  ADD_REG_REG,
  JMP_NOT_EQ,
  MOV_LIT_REG,
  MOV_MEM_REG,
  MOV_REG_MEM,
  POP,
  PSH_LIT,
  PSH_REG,
} from "../src/instructions"
import { createMemory } from "../src/memory"
import { Register } from "../src/util"

describe("CPU", () => {
  let cpu: CPU
  let memory: DataView

  beforeEach(() => {
    memory = createMemory(256 * 256)
    cpu = new CPU(memory)
  })

  it("should execute MOV_LIT_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1

    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x1234)
  })
  it("should execute ADD_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = ADD_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0xbe01)
  })
  it("should execute MOV_REG_MEM instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_REG_MEM
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00

    cpu.step()
    cpu.step()

    expect(memory.getUint16(0x0100)).toBe(0x1234)
  })
  it("should execute MOV_MEM_REG instruction correctly", () => {
    memory.setUint16(0x0100, 0x1234)

    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_MEM_REG
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1

    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x1234)
  })
  it("should execute JMP_NOT_EQ instruction correctly", () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_MEM_REG
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100
    writableBytes[i++] = Register.R1

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x01 // 0x0001
    writableBytes[i++] = Register.R2

    writableBytes[i++] = ADD_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = MOV_REG_MEM
    writableBytes[i++] = Register.ACC
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    writableBytes[i++] = JMP_NOT_EQ
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03 // 0x0003
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x00 // 0x0000

    expect(cpu.getRegister("ip")).toBe(0x0000)
  })
  it("should execute PSH_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x01 // 0x0001

    cpu.step()

    expect(cpu.getRegister("sp")).toBe(0xfffc)
    expect(memory.getUint16(0xfffe)).toBe(0x0001)
  })

  it("should execute PSH_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x01 // 0x0001
    writableBytes[i++] = Register.R1

    writableBytes[i++] = PSH_REG
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("sp")).toBe(0xfffc)
    expect(memory.getUint16(0xfffe)).toBe(0x0001)
  })

  it("should execute POP instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x51
    writableBytes[i++] = 0x51
    writableBytes[i++] = Register.R1

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x42
    writableBytes[i++] = 0x42
    writableBytes[i++] = Register.R2

    writableBytes[i++] = PSH_REG
    writableBytes[i++] = Register.R1

    writableBytes[i++] = PSH_REG
    writableBytes[i++] = Register.R2

    writableBytes[i++] = POP
    writableBytes[i++] = Register.R1

    writableBytes[i++] = POP
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x4242)
    expect(cpu.getRegister("r2")).toBe(0x5151)
    expect(cpu.getRegister("sp")).toBe(0xfffe)
  })
})
