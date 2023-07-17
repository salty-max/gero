import { CPU } from "../src/cpu"
import {
  ADD_REG_REG,
  MOV_LIT_REG,
  MOV_MEM_REG,
  MOV_REG_MEM,
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
})
