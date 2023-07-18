import readline from "readline"
import { CPU } from "./cpu"

export const stepDebug = (cpu: CPU) => {
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
}
