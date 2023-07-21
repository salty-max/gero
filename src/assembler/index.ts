import P from 'parsil'
import parser from './parser'
import instructions, { InstructionType as I } from '../instructions'
import { Register } from '../util'
import { Node } from './parser/types'

const exampleProgram = [
  'mov $4200, r1',
  'mov r1, &0060',
  'mov $1300, r1',
  'mov &0060, r2',
  'add r1, r2',
].join('\n')

const output = parser.run(exampleProgram)

const machineCode: Array<number> = []

const encodeLitOrMem = (lit: Node) => {
  const hexVal = parseInt(lit.value, 16)
  const highByte = (hexVal & 0xff00) >> 8
  const lowByte = hexVal & 0x00ff
  machineCode.push(highByte, lowByte)
}

const encodeLit8 = (lit: Node) => {
  const hexVal = parseInt(lit.value, 16)
  const byte = hexVal & 0x00ff
  machineCode.push(byte)
}

const encodeReg = (reg: Node) => {
  const mappedReg = Register[reg.value.toUpperCase()]
  machineCode.push(mappedReg)
}

if (P.isOk(output)) {
  output.result.forEach((it) => {
    const metadata = instructions[it.value.instruction]
    machineCode.push(metadata.opcode)
    if ([I.LIT_REG, I.MEM_REG].includes(metadata.type)) {
      encodeLitOrMem(it.value.args[0])
      encodeReg(it.value.args[1])
    }
    if ([I.REG_LIT, I.REG_MEM].includes(metadata.type)) {
      encodeReg(it.value.args[0])
      encodeLitOrMem(it.value.args[1])
    }
    if (I.REG_LIT_8 === metadata.type) {
      encodeReg(it.value.args[0])
      encodeLit8(it.value.args[1])
    }
    if ([I.REG_PTR_REG, I.REG_REG].includes(metadata.type)) {
      encodeReg(it.value.args[0])
      encodeReg(it.value.args[1])
    }
    if (I.LIT_MEM === metadata.type) {
      encodeLitOrMem(it.value.args[0])
      encodeLitOrMem(it.value.args[1])
    }
    if (I.LIT_OFF_REG === metadata.type) {
      encodeLitOrMem(it.value.args[0])
      encodeReg(it.value.args[1])
      encodeReg(it.value.args[2])
    }
    if (I.SINGLE_REG === metadata.type) {
      encodeReg(it.value.args[0])
    }
    if (I.SINGLE_LIT === metadata.type) {
      encodeLitOrMem(it.value.args[0])
    }
  })
} else {
  throw new Error(output.error)
}

console.log(machineCode.map((byte) => Number(byte).toString(16)).join(' '))
