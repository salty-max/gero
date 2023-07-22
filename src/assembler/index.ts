import parser from './parser'
import instructions, { InstructionType as I } from '../instructions'
import { Register } from '../util'
import { Node } from './parser/types'
import { parserResult } from './parser/util'

const exampleProgram = [
  'constant code_constant = $C0DE',
  '+data8 bytes = { $01, $02, $03, $04 }',
  'data16 words = { $0102, $0304, $0506, $0708 }',
  'start:',
  ' mov $0A, &0050',
  ' mov [!code_constant], &1234',
  'loop:',
  ' mov &0050, acu',
  ' dec acu',
  ' mov acu, &0050',
  ' inc r2',
  ' inc r2',
  ' inc r2',
  ' jne $00, &[!loop]',
  'end:',
  ' hlt',
]
  .join('\n')
  .trim()

/**
 * `parserProgram` parses a program string and returns machine code that can be executed by a virtual machine.
 * @param {string} program - The program to be parsed.
 * @returns {Array<number>} The resulting machine code, as an array of numeric values.
 */
export const parseProgram = (program: string): Array<number> => {
  const output = parser.run(program)

  if (output.isError) {
    throw new Error(output.error)
  }

  const machineCode: Array<number> = []
  const symbols: Record<string, number> = {}
  let currentAddress = 0

  // Step 1: Collect symbols and calculate the size of each instruction
  parserResult(output).result.forEach((node: Node) => {
    switch (node.type) {
      case 'LABEL':
        // Record the address of each label
        symbols[node.value] = currentAddress
        break
      case 'CONSTANT': {
        // Record the value of each constant
        symbols[node.value.name] = parseInt(node.value.value.value, 16) & 0xffff
        break
      }
      case 'DATA': {
        // Record the address of each data array
        symbols[node.value.name] = currentAddress
        // Increment the current address based on the size of the data array
        const sizeInBytes = node.value.size === 16 ? 2 : 1
        // Multiply the size of the data array by the number of values in the array
        const totalSizeInBytes = sizeInBytes * node.value.values.length
        // Increment the current address by the total size of the data array
        currentAddress += totalSizeInBytes
        break
      }
      default: {
        // Look up the metadata for each instruction
        const metadata = instructions[node.value.instruction]
        // Increment the current address based on the size of the instruction
        currentAddress += metadata.size
      }
    }
  })

  const encodeLitOrMem = (lit: Node) => {
    // Determine the value of the literal based on its type (variable or immediate)
    let hexVal
    if (lit.type === 'VARIABLE') {
      // Resolve the label address for variables
      if (!(lit.value in symbols)) {
        throw new Error(`label '${lit.value}' was not resolved`)
      }
      hexVal = symbols[lit.value]
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
      if (!(lit.value in symbols)) {
        throw new Error(`label '${lit.value}' was not resolved`)
      }
      hexVal = symbols[lit.value]
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

  const encodeData8 = (data: Node) => {
    for (const byte of data.value.values) {
      // Parse the hexadecimal value and push it to the machineCode array
      const parsed = parseInt(byte.value, 16)
      // Ensure that the value is 8 bits
      machineCode.push(parsed & 0xff)
    }
  }

  const encodeData16 = (data: Node) => {
    for (const byte of data.value.values) {
      // Parse the hexadecimal value and push it to the machineCode array
      const parsed = parseInt(byte.value, 16)
      // Ensure that the value is 16 bits
      machineCode.push((parsed & 0xff00) >> 8) // high byte
      machineCode.push(parsed & 0xff) // low byte
    }
  }

  // Step 2: Encode each instruction and its arguments into machine code
  parserResult(output).result.forEach((node: Node) => {
    // Skip symbols
    if (node.type === 'LABEL' || node.type === 'CONSTANT') return

    if (node.type === 'DATA') {
      if (node.value.size === 8) {
        encodeData8(node)
      } else {
        encodeData16(node)
      }
      return
    }

    // Look up the metadata for the instruction
    const metadata = instructions[node.value.instruction]
    // Push the opcode of the instruction to the machineCode array
    machineCode.push(metadata.opcode)

    // Choose the appropriate encoding method based on the type of instruction
    if ([I.LIT_REG, I.MEM_REG].includes(metadata.type)) {
      encodeLitOrMem(node.value.args[0])
      encodeReg(node.value.args[1])
    }
    if ([I.REG_LIT, I.REG_MEM].includes(metadata.type)) {
      encodeReg(node.value.args[0])
      encodeLitOrMem(node.value.args[1])
    }
    if (I.REG_LIT_8 === metadata.type) {
      encodeReg(node.value.args[0])
      encodeLit8(node.value.args[1])
    }
    if ([I.REG_PTR_REG, I.REG_REG].includes(metadata.type)) {
      encodeReg(node.value.args[0])
      encodeReg(node.value.args[1])
    }
    if (I.LIT_MEM === metadata.type) {
      encodeLitOrMem(node.value.args[0])
      encodeLitOrMem(node.value.args[1])
    }
    if (I.LIT_OFF_REG === metadata.type) {
      encodeLitOrMem(node.value.args[0])
      encodeReg(node.value.args[1])
      encodeReg(node.value.args[2])
    }
    if (I.SINGLE_REG === metadata.type) {
      encodeReg(node.value.args[0])
    }
    if (I.SINGLE_LIT === metadata.type) {
      encodeLitOrMem(node.value.args[0])
    }
    if (I.SINGLE_ADDR === metadata.type) {
      encodeLitOrMem(node.value.args[0])
    }
  })

  return machineCode
}

/**
 * `machineCodeAsHex` converts an array of machine codes into a hexadecimal representation.
 * @param {Array<number>} code - The array of machine codes to be converted.
 * @returns {string} The resulting string of hexadecimal values.
 */
export const machineCodeAsHex = (code: Array<number>) => {
  return code
    .map((byte) => `0x${byte.toString(16).padStart(2, '0').toUpperCase()}`)
    .join(' ')
}

/**
 * `machineCodeAsBinary` converts an array of machine codes into a binary representation.
 * @param {Array<number>} code - The array of machine codes to be converted.
 * @returns {string} The resulting string of binary values.
 */
export const machineCodeAsBinary = (code: Array<number>) =>
  code.map((byte) => byte.toString(2)).join(' ')

/**
 * `machineCodeAsDecimal` converts an array of machine codes into a decimal representation.
 * @param {Array<number>} code - The array of machine codes to be converted.
 * @returns {string} The resulting string of decimal values.
 */
export const machineCodeAsDecimal = (code: Array<number>) => code.join(' ')

//console.log(machineCodeAsDecimal(parseProgram(exampleProgram)))
console.log(machineCodeAsHex(parseProgram(exampleProgram)))
//console.log(machineCodeAsBinary(parseProgram(exampleProgram)))
