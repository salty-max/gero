import path from 'path'

import parser from './parser'
import instructions, { InstructionType as I } from '../instructions'
import { Register } from '../util'
import { Export, Node, Struct } from './parser/types'
import { parserResult } from './parser/util'
import {
  //ANSI_COLOR_BLUE,
  ANSI_COLOR_BOLD,
  ANSI_COLOR_RESET,
} from '../util/util'
//import { topLevelModule } from './parser/module'

/**
 * `processModule` parses a module string and returns machine code that can be executed by a virtual machine.
 * @param module string
 * @param loc number
 * @returns A tuple of machine code, symbols, structs, and exports
 */
const processModule = (module: string, loc = 0) => {
  const output = parser.run(module)

  if (output.isError) {
    throw new Error(output.error)
  }

  const machineCode: Array<number> = []
  const symbols: Record<string, number> = {}
  const structs: Record<string, Struct> = {}
  const exports: Record<string, Export> = {}
  let currentAddress = loc

  // Step 1: Collect symbols and calculate the size of each instruction
  parserResult(output).result.forEach((node: Node) => {
    switch (node.type) {
      case 'LABEL':
        if (node.value in symbols || node.value in structs) {
          throw new Error(
            `Can't create label '${node.value}' because a binding with the same name already exists`
          )
        }
        // Record the address of each label
        symbols[node.value] = currentAddress

        if (node.value.isExport) {
          exports[node.value.name] = { type: 'symbol', value: node.value.name }
        }
        break
      case 'CONSTANT': {
        if (node.value in symbols || node.value in structs) {
          throw new Error(
            `Can't create constant '${node.value}' because a binding with the same name already exists`
          )
        }
        // Record the value of each constant
        symbols[node.value.name] = parseInt(node.value.value.value, 16) & 0xffff

        if (node.value.isExport) {
          exports[node.value.name] = {
            type: 'symbol',
            value: node.value.name,
          }
        }
        break
      }
      case 'DATA': {
        if (node.value in symbols || node.value in structs) {
          throw new Error(
            `Can't create data '${node.value}' because a binding with the same name already exists`
          )
        }
        // Record the address of each data array
        symbols[node.value.name] = currentAddress

        if (node.value.isExport) {
          exports[node.value.name] = {
            type: 'symbol',
            value: node.value.name,
          }
        }

        // Increment the current address based on the size of the data array
        const sizeInBytes = node.value.size === 16 ? 2 : 1
        // Multiply the size of the data array by the number of values in the array
        const totalSizeInBytes = sizeInBytes * node.value.values.length
        // Increment the current address by the total size of the data array
        currentAddress += totalSizeInBytes
        break
      }
      case 'STRUCT': {
        if (node.value in symbols || node.value in structs) {
          throw new Error(
            `Can't create struct '${node.value}' because a binding with the same name already exists`
          )
        }

        structs[node.value.name] = {
          members: {},
        }

        let offset = 0
        for (const { key, value } of node.value.members) {
          structs[node.value.name].members[key] = {
            offset,
            size: parseInt(value.value, 16) & 0xffff,
          }
          offset += structs[node.value.name].members[key].size
        }

        if (node.value.isExport) {
          exports[node.value.name] = {
            type: 'struct',
            value: node.value.name,
          }
        }
        break
      }
      default: {
        // Look up the metadata for each instruction
        const metadata = instructions[node.value.instruction]
        // Increment the current address based on the size of the instruction
        currentAddress += metadata.size
        break
      }
    }
  })

  const getNodeValue = (node: Node) => {
    // Determine the value of the literal based on its type (variable or immediate)
    switch (node.type) {
      case 'VARIABLE':
        // Resolve the label address for variables
        if (!(node.value in symbols)) {
          throw new Error(`label '${node.value}' was not resolved`)
        }
        return symbols[node.value]
      case 'ADDRESS':
      case 'HEX_LITERAL': {
        return parseInt(node.value, 16)
      }
      case 'INTERPRET_AS': {
        const struct = structs[node.value.struct]
        if (!struct) {
          throw new Error(`struct '${node.value.struct}' was not resolved`)
        }

        const member = struct.members[node.value.property]
        if (!member) {
          throw new Error(
            `struct '${node.value.struct}' does not have a property '${node.value.property}'`
          )
        }

        if (!(node.value.symbol in symbols)) {
          throw new Error(`symbol '${node.value.symbol}' was not resolved`)
        }
        const symbol = symbols[node.value.symbol]
        return symbol + member.offset
      }
      default:
        throw new Error(`Unexpected node type: ${node.type}`)
    }
  }

  const encodeLitOrMem = (lit: Node) => {
    const hexVal = getNodeValue(lit)
    // Split the value into two bytes (high and low byte) and push them to the machineCode array
    const highByte = (hexVal & 0xff00) >> 8
    const lowByte = hexVal & 0x00ff
    machineCode.push(highByte, lowByte)
  }
  const encodeLit8 = (lit: Node) => {
    const hexVal = getNodeValue(lit)
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
    if (
      node.type === 'LABEL' ||
      node.type === 'CONSTANT' ||
      node.type === 'STRUCT' ||
      node.type === 'TOP_LEVEL_MODULE'
    )
      return

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
    if ([I.REG_PTR_REG, I.REG_REG_PTR, I.REG_REG].includes(metadata.type)) {
      encodeReg(node.value.args[0])
      encodeReg(node.value.args[1])
    }
    if (I.LIT_MEM === metadata.type) {
      encodeLitOrMem(node.value.args[0])
      encodeLitOrMem(node.value.args[1])
    }
    if (I.LIT_MEM_8 === metadata.type) {
      encodeLit8(node.value.args[0])
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

  return { machineCode, symbols }
}

/**
 * `assembleFile` parses a main module and all of its imports and returns machine code that can be executed by a virtual machine.
 * @param {string} mainModulePath - The main file path.
 * @returns {Promise<{ machineCode: number[], symbols: Record<string, number>, structs: Record<string, Struct>, exports: Record<string, Export> }>} The resulting machine code, symbols, structs, and exports.
 */
export const assemble = async (mainModulePath: string, offset = 0) => {
  const cwd = process.cwd()
  const joinedPath = path.join(cwd, mainModulePath)

  const res = await fetch(joinedPath)
  const mainFileString = await res.text()

  return processModule(mainFileString, offset)
}

/**
 * `assembleString` parses a module string and returns machine code that can be executed by a virtual machine.
 * @param program The program string to be assembled.
 * @returns {Module} The resulting machine code, symbols, structs, and exports.
 */
export const assembleString = (program: string, offset = 0) =>
  processModule(program, offset)

/**
 * `machineCodeAsHex` converts an array of machine codes into a hexadecimal representation.
 * @param {Array<number>} code - The array of machine codes to be converted.
 * @returns {string} The resulting string of hexadecimal values.
 */
export const machineCodeAsHex = (code: Array<number>, color?: string) => {
  return code
    .map(
      (byte) =>
        `0x${color ? color + ANSI_COLOR_BOLD : ''}${byte
          .toString(16)
          .padStart(2, '0')
          .toUpperCase()}${color ? ANSI_COLOR_RESET : ''}`
    )
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

// assemble('asm/main.mod').then((program) =>
//   console.log(machineCodeAsHex(program, ANSI_COLOR_BLUE))
// )

//console.log(machineCodeAsDecimal(parseProgram(exampleProgram)))
//console.log(machineCodeAsBinary(parseProgram(exampleProgram)))
