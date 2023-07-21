import parser from './parser'
import instructions, { InstructionType as I } from '../instructions'
import { Register } from '../util'
import { Node } from './parser/types'
import { deepLog, parserResult } from './parser/util'

const exampleProgram = [
  'start:',
  ' mov $0A, &0050',
  'loop:',
  ' mov &0050, acc',
  ' dec acc',
  ' mov acc, &0050',
  ' inc r2',
  ' inc r2',
  ' inc r2',
  ' jne $00, &[!loop]',
  'end:',
  ' hlt',
].join('\n')

export const parseProgram = (program: string): Array<number> => {
  const output = parser.run(program)

  const machineCode: Array<number> = []
  const labels: Record<Node['value'], number> = {}
  let currentAddress = 0

  // Step 1: Collect labels and calculate the size of each instruction
  parserResult(output).result.forEach((node: Node) => {
    if (node.type === 'LABEL') {
      // Record the address of each label
      labels[node.value] = currentAddress
    } else {
      // Look up the metadata for each instruction
      const metadata = instructions[node.value.instruction]
      // Increment the current address based on the size of the instruction
      currentAddress += metadata.size
    }
  })

  const encodeLitOrMem = (lit: Node) => {
    // Determine the value of the literal based on its type (variable or immediate)
    let hexVal
    if (lit.type === 'VARIABLE') {
      // Resolve the label address for variables
      if (!(lit.value in labels)) {
        throw new Error(`label '${lit.value}' was not resolved`)
      }
      hexVal = labels[lit.value]
    } else {
      hexVal = parseInt(lit.value, 16)
    }
    // Split the value into two bytes (high and low byte) and push them to the machineCode array
    const highByte = (hexVal & 0xff00) >> 8
    const lowByte = hexVal & 0x00ff
    machineCode.push(highByte, lowByte)
  }

  const encodeLit8 = (lit: Node) => {
    // Determine the value of the literal based on its type (variable or immediate)
    let hexVal
    if (lit.type === 'VARIABLE') {
      // Resolve the label address for variables
      if (!(lit.value in labels)) {
        throw new Error(`label '${lit.value}' was not resolved`)
      }
      hexVal = labels[lit.value]
    } else {
      hexVal = parseInt(lit.value, 16)
    }
    // Push the 8-bit value to the machineCode array
    const byte = hexVal & 0x00ff
    machineCode.push(byte)
  }

  const encodeReg = (reg: Node) => {
    // Map the register string to its corresponding numeric value and push it to the machineCode array
    const mappedReg = Register[reg.value.toUpperCase()]
    machineCode.push(mappedReg)
  }

  // Step 2: Encode each instruction and its arguments into machine code
  parserResult(output).result.forEach((it: Node) => {
    if (it.type !== 'INSTRUCTION') return

    // Look up the metadata for the instruction
    const metadata = instructions[it.value.instruction]
    // Push the opcode of the instruction to the machineCode array
    machineCode.push(metadata.opcode)

    // Choose the appropriate encoding method based on the type of instruction
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

  return machineCode
}

export const machineCode16 = (code: Array<number>) =>
  code
    .map((byte) => Number(byte).toString(16).padStart(2, '0').toUpperCase())
    .join(' ')

export const machineCode10 = (code: Array<number>) => code.join(' ')

deepLog(machineCode10(parseProgram(exampleProgram)))
deepLog(machineCode16(parseProgram(exampleProgram)))
