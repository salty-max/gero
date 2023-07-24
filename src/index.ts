import {
  BANKS_COUNT,
  BANK_SIZE,
  createBankedMemory,
} from './devices/memory-bank'
import { createRAM } from './vm'
import { CPU } from './vm/cpu'
import { MemoryMapper } from './vm/memory-mapper'

const MM = new MemoryMapper()
const cpu = new CPU(MM)
const memoryBank = createBankedMemory(BANKS_COUNT, BANK_SIZE, cpu)
MM.map(memoryBank, 0, BANK_SIZE)

const regularMemory = createRAM(0xff00)
MM.map(regularMemory, BANK_SIZE, 0xffff, true)
