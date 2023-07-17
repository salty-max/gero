import readline from "readline"
import { createMemory } from "./memory"
import { CPU } from "./cpu"
import { CAL_LIT, MOV_LIT_REG, PSH_LIT, RET } from "./instructions"
import { Register } from "./util"

const memory = createMemory(256 * 256)
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

const cpu = new CPU(memory)

cpu.debug()
cpu.viewMemoryAt(cpu.getRegister("ip"))
cpu.viewMemoryAt(0xffff - 1 - 42, 44)

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
})

rl.on("line", () => {
  cpu.step()
  cpu.debug()
  cpu.viewMemoryAt(cpu.getRegister("ip"))
  cpu.viewMemoryAt(0xffff - 1 - 42, 44)
})
