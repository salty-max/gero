import readline from "readline"
import { createMemory } from "./memory"
import { CPU } from "./cpu"
import {
  ADD_REG_REG,
  JMP_NOT_EQ,
  MOV_LIT_REG,
  MOV_MEM_REG,
  MOV_REG_MEM,
} from "./instructions"
import { Register } from "./util"

const memory = createMemory(256 * 256)
const writableBytes = new Uint8Array(memory.buffer)

let i = 0

memory.setUint16(0x0100, 0x0000)

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
writableBytes[i++] = 0x00 // 0x0100

const cpu = new CPU(memory)

cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0x0100)

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
})

rl.on("line", () => {
  cpu.step()
  cpu.debug()
  cpu.viewMemoryAt(cpu.getRegister("ip"))
  cpu.viewMemoryAt(0x0100)
})
