import readline from "readline"
import { createMemory } from "./memory"
import { CPU } from "./cpu"
import { MOV_LIT_REG, POP, PSH_REG } from "./instructions"
import { Register } from "./util"

const memory = createMemory(256 * 256)
const writableBytes = new Uint8Array(memory.buffer)

let i = 0

memory.setUint16(0x0100, 0x0000)

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

const cpu = new CPU(memory)

cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0xffff - 1 - 6)

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
})

rl.on("line", () => {
  cpu.step()
  cpu.debug()
  cpu.viewMemoryAt(cpu.getRegister("ip"))
  cpu.viewMemoryAt(0xffff - 1 - 6)
})
