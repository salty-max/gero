import { CPU } from "../src/cpu"
import {
  ADD_LIT_REG,
  ADD_REG_REG,
  AND_REG_LIT,
  AND_REG_REG,
  CAL_LIT,
  DEC_REG,
  HLT,
  INC_REG,
  JMP_NOT_EQ,
  LSF_REG_LIT,
  LSF_REG_REG,
  MOV_LIT_MEM,
  MOV_LIT_OFF_REG,
  MOV_LIT_REG,
  MOV_MEM_REG,
  MOV_REG_MEM,
  MOV_REG_PTR_REG,
  MUL_LIT_REG,
  MUL_REG_REG,
  NOT,
  OR_REG_LIT,
  OR_REG_REG,
  POP,
  PSH_LIT,
  PSH_REG,
  RET,
  RSF_REG_LIT,
  RSF_REG_REG,
  SUB_LIT_REG,
  SUB_REG_LIT,
  SUB_REG_REG,
  XOR_REG_LIT,
  XOR_REG_REG,
} from "../src/instructions"
import { createMemory } from "../src/memory"
import { MemoryMapper } from "../src/memory-mapper"
import { Register } from "../src/util"

describe("Instructions", () => {
  let cpu: CPU
  let memory: DataView
  let MM: MemoryMapper

  beforeEach(() => {
    memory = createMemory(256 * 256)
    MM = new MemoryMapper()
    MM.map(memory, 0x0000, 0xffff)
    cpu = new CPU(MM)
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
  it("should execute MOV_LIT_MEM instruction correctly", () => {
    memory.setUint16(0x0100, 0x1234)

    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_LIT_MEM
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00

    cpu.step()

    expect(memory.getUint16(0x0100)).toBe(0x1234)
  })
  it("should execute MOV_REG_PTR_REG instruction correctly", () => {
    memory.setUint16(0x0100, 0x1234)

    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = MOV_REG_PTR_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r2")).toBe(0x1234)
  })
  it("should execute MOV_LIT_OFF_REG instruction correctly", () => {
    memory.setUint16(0x0102, 0x1234)

    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_OFF_REG
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r2")).toBe(0x1234)
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
  it("should execute ADD_LIT_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1
    writableBytes[i++] = ADD_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0xbe01)
  })
  it("should execute SUB_LIT_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = SUB_LIT_REG
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x9999)
  })
  it("should execute SUB_REG_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1
    writableBytes[i++] = SUB_REG_LIT
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x9999)
  })
  it("should execute SUB_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R2
    writableBytes[i++] = SUB_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x9999)
  })
  it("should execute MUL_LIT_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MUL_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x0006)
  })
  it("should execute MUL_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03
    writableBytes[i++] = Register.R2
    writableBytes[i++] = MUL_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x0006)
  })
  it("should execute INC_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = INC_REG
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x0003)
  })
  it("should execute DEC_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = DEC_REG
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x0001)
  })
  it("should execute LSF_REG_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = LSF_REG_LIT
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 2

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x48d0)
  })
  it("should execute LSF_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R2
    writableBytes[i++] = LSF_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x48d0)
  })
  it("should execute RSF_REG_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = RSF_REG_LIT
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 2

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x048d)
  })
  it("should execute RSF_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R2
    writableBytes[i++] = RSF_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("r1")).toBe(0x048d)
  })
  it("should execute AND_REG_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = AND_REG_LIT
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0xff

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x0034)
  })
  it("should execute AND_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff
    writableBytes[i++] = Register.R2
    writableBytes[i++] = AND_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x0034)
  })
  it("should execute OR_REG_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = OR_REG_LIT
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0xff

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x12ff)
  })
  it("should execute OR_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff
    writableBytes[i++] = Register.R2
    writableBytes[i++] = OR_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x12ff)
  })
  it("should execute XOR_REG_LIT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = XOR_REG_LIT
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0xff

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x12cb)
  })
  it("should execute XOR_REG_REG instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff
    writableBytes[i++] = Register.R2
    writableBytes[i++] = XOR_REG_REG
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0x12cb)
  })
  it("should execute NOT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    console.log(~0x1234 & 0xffff)
    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = NOT
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister("acc")).toBe(0xedcb)
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
  it("should execute CAL_LIT and RET while maintaining stack integrity and restore state correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)

    const subroutineAddress = 0x0680
    let i = 0

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x33
    writableBytes[i++] = 0x33 // Ox3333

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x22
    writableBytes[i++] = 0x22 // Ox2222

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x11
    writableBytes[i++] = 0x11 // Ox1111

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34 // Ox1234
    writableBytes[i++] = Register.R1

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x56
    writableBytes[i++] = 0x78 // Ox5678
    writableBytes[i++] = Register.R4

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x00 // Ox0000

    writableBytes[i++] = CAL_LIT
    writableBytes[i++] = (subroutineAddress & 0xff00) >> 8
    writableBytes[i++] = subroutineAddress & 0x00ff

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x44
    writableBytes[i++] = 0x44 // Ox4444

    // Subroutine...
    i = subroutineAddress

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x02 // Ox0102

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x03
    writableBytes[i++] = 0x04 // Ox0304

    writableBytes[i++] = PSH_LIT
    writableBytes[i++] = 0x05
    writableBytes[i++] = 0x06 // Ox0506

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x07
    writableBytes[i++] = 0x08 // Ox0708
    writableBytes[i++] = Register.R1

    writableBytes[i++] = MOV_LIT_REG
    writableBytes[i++] = 0x09
    writableBytes[i++] = 0x0a // Ox090A
    writableBytes[i++] = Register.R8

    writableBytes[i++] = RET

    for (let i = 0; i < 14; i++) {
      cpu.step()
    }

    expect(cpu.getRegister("ip")).toBe(0x001a)
    expect(cpu.getRegister("r1")).toBe(0x1234)
    expect(cpu.getRegister("r4")).toBe(0x5678)
    expect(cpu.getRegister("sp")).toBe(0xfff6)
    expect(cpu.getRegister("fp")).toBe(0xfffe)
    expect(memory.getUint16(0xfff8)).toBe(0x4444)
  })
  it("should execute HLT instruction correctly", () => {
    const writableBytes = new Uint8Array(memory.buffer)
    let i = 0
    writableBytes[i++] = HLT

    const res = cpu.step()

    expect(res).toBe(true)
  })
})
