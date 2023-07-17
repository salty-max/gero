import { createMemory } from "./memory"
import { CPU } from "./cpu"
import { ADD_REG_REG, MOV_LIT_REG, MOV_REG_MEM } from "./instructions"
import { Register } from "./util"

const memory = createMemory(256 * 256)
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

writableBytes[i++] = MOV_REG_MEM
writableBytes[i++] = Register.ACC
writableBytes[i++] = 0x01
writableBytes[i++] = 0x00

const cpu = new CPU(memory)

cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0x0100)
cpu.step()
cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0x0100)
cpu.step()
cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0x0100)
cpu.step()
cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0x0100)
cpu.step()
cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0x0100)
