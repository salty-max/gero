import { createMemory } from './vm/memory'
import { CPU } from './vm/cpu'
import { HLT, MOV_LIT_REG, MOV_REG_MEM } from './vm/instructions'
import { Register } from './util/util'
import { MemoryMapper } from './vm/memory-mapper'
import { createScreenDevice } from './devices/screen-device'
//import { stepDebug } from "./debug"

const MM = new MemoryMapper()

const memory = createMemory(256 * 256)
MM.map(memory, 0, 0xffff)

// Map 256 bytes of the address space to an "output device" - just stdout
MM.map(createScreenDevice(), 0x3000, 0x30ff, true)

const cpu = new CPU(MM)

const writableBytes = new Uint8Array(memory.buffer)
let i = 0

const writeCharToScreen = (char: string, position: number, command = 0x00) => {
  writableBytes[i++] = MOV_LIT_REG
  writableBytes[i++] = command
  writableBytes[i++] = char.charCodeAt(0)
  writableBytes[i++] = Register.R1

  writableBytes[i++] = MOV_REG_MEM
  writableBytes[i++] = Register.R1
  writableBytes[i++] = 0x30
  writableBytes[i++] = position
}

writeCharToScreen(' ', 0, 0xff)

for (let i = 0; i <= 0xff; i++) {
  const command = i % 2 == 0 ? 0x31 : 0x34
  writeCharToScreen('*', i, command)
}

writableBytes[i++] = HLT

//stepDebug(cpu)

cpu.run()
