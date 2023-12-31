import { CPU } from '../src/vm/cpu'
import I from '../src/instructions'
import { Memory, createRAM } from '../src/vm/memory'
import { MemoryMapper } from '../src/vm/memory-mapper'
import { Register } from '../src/util/register'

describe('Instructions', () => {
  let cpu: CPU
  let memory: Memory
  let MM: MemoryMapper

  beforeEach(() => {
    memory = createRAM(256 * 256)
    MM = new MemoryMapper()
    MM.map(memory, 0x0000, 0xffff)
    cpu = new CPU(MM)
  })

  it('should execute MOV_LIT_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1

    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x1234)
  })
  it('should execute MOV_REG_MEM instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_REG_MEM.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00

    cpu.step()
    cpu.step()

    expect(memory.getUint16(0x0100)).toBe(0x1234)
  })
  it('should execute MOV_MEM_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x1234)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_MEM_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1

    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x1234)
  })
  it('should execute MOV_LIT_MEM instruction correctly', () => {
    memory.setUint16(0x0100, 0x0020)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_MEM.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00

    cpu.step()

    expect(memory.getUint16(0x0100)).toBe(0x1234)
  })
  it('should execute MOV_REG_PTR_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x1234)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.MOV_REG_PTR_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r2')).toBe(0x1234)
  })
  it('should execute MOV_REG_REG_PTR instruction correctly', () => {
    memory.setUint16(0x0100, 0x02)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.MOV_REG_REG_PTR.opcode
    writableBytes[i++] = Register.R2
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()
    cpu.step()

    expect(memory.getUint16(0x0100)).toBe(0xabcd)
  })
  it('should execute MOV_LIT_OFF_REG instruction correctly', () => {
    memory.setUint16(0x0102, 0x1234)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_OFF_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r2')).toBe(0x1234)
  })
  it('should execute MOV8_LIT_MEM instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV8_LIT_MEM.opcode
    writableBytes[i++] = 0x02
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34

    cpu.step()

    expect(memory.getUint8(0x1234)).toBe(0x02)
  })
  it('should execute MOV8_MEM_REG instruction correctly', () => {
    memory.setUint8(0x0200, 0x02)
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV8_MEM_REG.opcode
    writableBytes[i++] = 0x02
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1

    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x02)
  })
  it('should execute MOVL_REG_MEM instruction correctly', () => {
    memory.setUint8(0x0200, 0x02)
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xc0
    writableBytes[i++] = 0xde
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOVL_REG_MEM.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x02
    writableBytes[i++] = 0x00

    cpu.step()
    cpu.step()

    expect(memory.getUint8(0x0200)).toBe(0xde)
  })
  it('should execute MOVH_REG_MEM instruction correctly', () => {
    memory.setUint8(0x0200, 0x02)
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xc0
    writableBytes[i++] = 0xde
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOVH_REG_MEM.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x02
    writableBytes[i++] = 0x00

    cpu.step()
    cpu.step()

    expect(memory.getUint8(0x0200)).toBe(0xc0)
  })
  it('should execute MOV8_REG_PTR_REG instruction correctly', () => {
    memory.setUint8(0x0100, 0x02)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.MOV8_REG_PTR_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.setDebugMode(true)
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.setDebugMode(false)

    expect(cpu.getRegister('r2')).toBe(0x0002)
  })
  it('should execute MOV8_REG_REG_PTR instruction correctly', () => {
    memory.setUint16(0x0100, 0x02)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.MOV8_REG_REG_PTR.opcode
    writableBytes[i++] = Register.R2
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()
    cpu.step()

    expect(memory.getUint8(0x0100)).toBe(0xcd)
  })
  it('should execute ADD_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.ADD_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0xbe01)
  })
  it('should execute ADD_LIT_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.ADD_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0xbe01)
  })
  it('should execute SUB_LIT_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.SUB_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x9999)
  })
  it('should execute SUB_REG_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.SUB_REG_LIT.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x01

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x0002)
  })
  it('should execute SUB_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0xab
    writableBytes[i++] = 0xcd
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.SUB_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x9999)
  })
  it('should execute MUL_LIT_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MUL_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x0006)
  })
  it('should execute MUL_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x0006)
  })
  it('should execute INC_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.INC_REG.opcode
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x0003)
  })
  it('should execute DEC_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.DEC_REG.opcode
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x0001)
  })
  it('should execute LSF_REG_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.LSF_REG_LIT.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 2

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x48d0)
  })
  it('should execute LSF_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.LSF_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x48d0)
  })
  it('should execute RSF_REG_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.RSF_REG_LIT.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 2

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x048d)
  })
  it('should execute RSF_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.RSF_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x048d)
  })
  it('should execute AND_REG_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.AND_REG_LIT.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x0034)
  })
  it('should execute AND_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.AND_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x0034)
  })
  it('should execute OR_REG_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.OR_REG_LIT.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x12ff)
  })
  it('should execute OR_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.OR_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x12ff)
  })
  it('should execute XOR_REG_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.XOR_REG_LIT.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x12cb)
  })
  it('should execute XOR_REG_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0xff
    writableBytes[i++] = Register.R2
    writableBytes[i++] = I.XOR_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0x12cb)
  })
  it('should execute NOT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.NOT.opcode
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('acu')).toBe(0xedcb)
  })
  it('should execute JNE_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x05 // 0x0005
    writableBytes[i++] = Register.R3

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JNE_REG.opcode
    writableBytes[i++] = Register.R3
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JNE_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JNE_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03 // 0x0003
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JEQ_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x04 // 0x0004
    writableBytes[i++] = Register.R3

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JEQ_REG.opcode
    writableBytes[i++] = Register.R3
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JEQ_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JEQ_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x04 // 0x0004
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JLT_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03 // 0x0003
    writableBytes[i++] = Register.R3

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JLT_REG.opcode
    writableBytes[i++] = Register.R3
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JLT_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JLT_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03 // 0x0003
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JGT_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x05 // 0x0005
    writableBytes[i++] = Register.R3

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JGT_REG.opcode
    writableBytes[i++] = Register.R3
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JGT_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JGT_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x05 // 0x0005
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JLE_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03 // 0x0003
    writableBytes[i++] = Register.R3

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JLE_REG.opcode
    writableBytes[i++] = Register.R3
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JLE_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JLE_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x03 // 0x0003
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JGE_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x05 // 0x0005
    writableBytes[i++] = Register.R3

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JGE_REG.opcode
    writableBytes[i++] = Register.R3
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JGE_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x02 // 0x0002
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.MUL_REG_REG.opcode
    writableBytes[i++] = Register.R1
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.JGE_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x05 // 0x0005
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })
  it('should execute JMP_LIT instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.JMP_LIT.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100

    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })

  it('should execute JMP_REG instruction correctly', () => {
    memory.setUint16(0x0100, 0x0000)

    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x00 // 0x0100
    writableBytes[i++] = Register.R1
    writableBytes[i++] = I.JMP_REG.opcode
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('ip')).toBe(0x0100)
  })

  it('should execute PSH_LIT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x01 // 0x0001

    cpu.step()

    expect(cpu.getRegister('sp')).toBe(0xfffc)
    expect(memory.getUint16(0xfffe)).toBe(0x0001)
  })

  it('should execute PSH_REG instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x01 // 0x0001
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.PSH_REG.opcode
    writableBytes[i++] = Register.R1

    cpu.step()
    cpu.step()

    expect(cpu.getRegister('sp')).toBe(0xfffc)
    expect(memory.getUint16(0xfffe)).toBe(0x0001)
  })

  it('should execute POP instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x51
    writableBytes[i++] = 0x51
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x42
    writableBytes[i++] = 0x42
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.PSH_REG.opcode
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.PSH_REG.opcode
    writableBytes[i++] = Register.R2

    writableBytes[i++] = I.POP.opcode
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.POP.opcode
    writableBytes[i++] = Register.R2

    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()
    cpu.step()

    expect(cpu.getRegister('r1')).toBe(0x4242)
    expect(cpu.getRegister('r2')).toBe(0x5151)
    expect(cpu.getRegister('sp')).toBe(0xfffe)
  })
  it('should execute CAL_LIT and RET while maintaining stack integrity and restore state correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)

    const subroutineAddress = 0x0680
    let i = 0

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x33
    writableBytes[i++] = 0x33 // Ox3333

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x22
    writableBytes[i++] = 0x22 // Ox2222

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x11
    writableBytes[i++] = 0x11 // Ox1111

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x12
    writableBytes[i++] = 0x34 // Ox1234
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x56
    writableBytes[i++] = 0x78 // Ox5678
    writableBytes[i++] = Register.R4

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x00
    writableBytes[i++] = 0x00 // Ox0000

    writableBytes[i++] = I.CAL_LIT.opcode
    writableBytes[i++] = (subroutineAddress & 0xff00) >> 8
    writableBytes[i++] = subroutineAddress & 0x00ff

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x44
    writableBytes[i++] = 0x44 // Ox4444

    // Subroutine...
    i = subroutineAddress

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x01
    writableBytes[i++] = 0x02 // Ox0102

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x03
    writableBytes[i++] = 0x04 // Ox0304

    writableBytes[i++] = I.PSH_LIT.opcode
    writableBytes[i++] = 0x05
    writableBytes[i++] = 0x06 // Ox0506

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x07
    writableBytes[i++] = 0x08 // Ox0708
    writableBytes[i++] = Register.R1

    writableBytes[i++] = I.MOV_LIT_REG.opcode
    writableBytes[i++] = 0x09
    writableBytes[i++] = 0x0a // Ox090A
    writableBytes[i++] = Register.R8

    writableBytes[i++] = I.RET.opcode

    for (let i = 0; i < 14; i++) {
      cpu.step()
    }

    expect(cpu.getRegister('ip')).toBe(0x001a)
    expect(cpu.getRegister('r1')).toBe(0x1234)
    expect(cpu.getRegister('r4')).toBe(0x5678)
    expect(cpu.getRegister('sp')).toBe(0xfff6)
    expect(cpu.getRegister('fp')).toBe(0xfffe)
    expect(memory.getUint16(0xfff8)).toBe(0x4444)
  })
  it('should execute HLT instruction correctly', () => {
    const writableBytes = new Uint8Array(memory.ab)
    let i = 0
    writableBytes[i++] = I.HLT.opcode
    const res = cpu.step()

    expect(res).toBe(true)
  })
})
