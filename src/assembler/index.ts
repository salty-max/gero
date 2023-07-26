import parser from './parser'
import instructions, { instructionTypes } from '../instructions'
import { REGISTER_NAMES } from '../util'
import { Export, Node, Program, Struct } from './parser/types'
import { parserResult } from './parser/util'
import { ANSI_COLOR_BOLD, ANSI_COLOR_RESET } from '../util/util'
//import { topLevelModule } from './parser/module'

const registerMap = REGISTER_NAMES.reduce(
  (map: Record<string, number>, regName: string, index: number) => {
    map[regName] = index
    return map
  },
  {}
)

/**
 * `processModule` parses a module string and returns machine code that can be executed by a virtual machine.
 * @param module string
 * @param loc number
 * @returns A tuple of machine code, symbols, structs, and exports
 */
const processModule = (module: string, loc = 0): Program => {
  const output = parser.run(module)

  if (output.isError) {
    console.log(module.slice(output.index, output.index + 100))
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
      case 'COMMENT': {
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

  const getNodeValue = (node: Node): any => {
    // Determine the value of the literal based on its type (variable or immediate)
    switch (node.type) {
      case 'VARIABLE':
        // Resolve the label address for variables
        if (!(node.value in symbols)) {
          throw new Error(`label '${node.value}' was not resolved`)
        }
        return symbols[node.value]
      case 'REGISTER':
        return registerMap[node.value]
      case 'ADDRESS':
      case 'HEX_LITERAL': {
        return parseInt(node.value, 16)
      }
      case 'BINARY_OPERATION': {
        const a: string = getNodeValue(node.value.a)
        const b: string = getNodeValue(node.value.b)
        switch (node.value.op.type) {
          case 'OP_PLUS':
            return (parseInt(a) + parseInt(b)) & 0xffff
          case 'OP_MINUS':
            return (parseInt(a) + parseInt(b)) & 0xffff
          case 'OP_MULTIPLY':
            return (parseInt(a) + parseInt(b)) & 0xffff
          default:
            throw new Error(`Unsupported operator: ${node.value.op.value}`)
        }
      }
      case 'GROUPED_EXPRESSION': {
        return node.value.map((node: Node) => {
          if (
            node.type === 'OP_PLUS' ||
            node.type === 'OP_MINUS' ||
            node.type === 'OP_MULTIPLY'
          ) {
            return
          }
          return getNodeValue(node)
        })
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

        if (node.value.symbol.type === 'ADDRESS') {
          return node.value.symbol.value + member.offset
        }

        if (!(node.value.symbol in symbols)) {
          throw new Error(`symbol '${node.value.symbol}' was not resolved`)
        }
        const symbol = symbols[node.value.symbol]
        return symbol + member.offset
      }
      default:
        throw new Error(`Unsupported node type: ${node.type}`)
    }
  }

  const dissassembly = output.result.map((node: Node) => {
    if (node.type === 'INSTRUCTION') {
      return [
        0,
        '\t' +
          node.value.instruction +
          ' ' +
          node.value.args
            .map((node: Node) => {
              if (node.type === 'BINARY_OPERATION') {
                const a: string = getNodeValue(node.value.a)
                const b: string = getNodeValue(node.value.b)
                switch (node.value.op.type) {
                  case 'OP_PLUS':
                    return ((parseInt(a) + parseInt(b)) & 0xffff).toString(16)
                  case 'OP_MINUS':
                    return ((parseInt(a) + parseInt(b)) & 0xffff).toString(16)
                  case 'OP_MULTIPLY':
                    return ((parseInt(a) + parseInt(b)) & 0xffff).toString(16)
                  default:
                    return NaN
                }
              }

              return node.value
            })
            .join(', '),
        node,
      ]
    }
    if (node.type === 'LABEL') {
      return [0, node.type + ' ' + node.value, node]
    }
    if (node.type === 'CONSTANT') {
      return [0, node.type + ' ' + node.value.name, node]
    }
    if (node.type === 'DATA') {
      return [0, node.type + node.value.size + ' ' + node.value.name, node]
    }
    return null
  })

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
    const mappedReg = registerMap[reg.value]
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
  parserResult(output).result.forEach((node: Node, i: number) => {
    if (node.type === 'COMMENT') {
      return
    }

    if (node.type === 'LABEL') {
      const disassemblyItem = dissassembly[i] as (string | number | Node)[]

      if (disassemblyItem === null) return

      disassemblyItem[0] = symbols[(disassemblyItem[2] as Node).value]
    }

    if (node.type === 'CONSTANT') {
      const disassemblyItem = dissassembly[i] as (string | number | Node)[]

      if (disassemblyItem === null) return
      disassemblyItem[0] = symbols[(disassemblyItem[2] as Node).value.name]
    }
    if (node.type === 'CONSTANT') {
      const disassemblyItem = dissassembly[i] as (string | number | Node)[]

      if (disassemblyItem === null) return
      disassemblyItem[0] = symbols[(disassemblyItem[2] as Node).value.name]
    }
    // Skip symbols
    if (
      node.type === 'LABEL' ||
      node.type === 'CONSTANT' ||
      node.type === 'STRUCT'
    )
      return

    if (node.type === 'DATA') {
      const disassemblyItem = dissassembly[i] as (string | number | Node)[]

      if (disassemblyItem === null) return
      disassemblyItem[0] = symbols[(disassemblyItem[2] as Node).value.name]

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
    if (
      [
        instructionTypes.litReg,
        instructionTypes.memReg,
        instructionTypes.litRegPtr,
      ].includes(metadata.type)
    ) {
      encodeLitOrMem(node.value.args[0])
      encodeReg(node.value.args[1])
    }
    if (
      [instructionTypes.regLit, instructionTypes.regMem].includes(metadata.type)
    ) {
      encodeReg(node.value.args[0])
      encodeLitOrMem(node.value.args[1])
    }
    if (instructionTypes.regLit8 === metadata.type) {
      encodeReg(node.value.args[0])
      encodeLit8(node.value.args[1])
    }
    if (
      [
        instructionTypes.regPtrReg,
        instructionTypes.regRegPtr,
        instructionTypes.regReg,
      ].includes(metadata.type)
    ) {
      encodeReg(node.value.args[0])
      encodeReg(node.value.args[1])
    }
    if (instructionTypes.litMem === metadata.type) {
      encodeLitOrMem(node.value.args[0])
      encodeLitOrMem(node.value.args[1])
    }
    if (instructionTypes.litMem8 === metadata.type) {
      encodeLit8(node.value.args[0])
      encodeLitOrMem(node.value.args[1])
    }
    if (instructionTypes.litOffReg === metadata.type) {
      encodeLitOrMem(node.value.args[0])
      encodeReg(node.value.args[1])
      encodeReg(node.value.args[2])
    }
    if (instructionTypes.singleReg === metadata.type) {
      encodeReg(node.value.args[0])
    }
    if (instructionTypes.singleLit === metadata.type) {
      encodeLitOrMem(node.value.args[0])
    }
    if (instructionTypes.singleAddr === metadata.type) {
      encodeLitOrMem(node.value.args[0])
    }
  })

  console.log(
    dissassembly
      .map((d) => {
        return !d ? '' : `0x${d[0].toString(16).padStart(4, '0')}: ${d[1]}`
      })
      .join('\n')
  )

  return { machineCode, symbols }
}

/**
 * `assembleFile` parses a main module and all of its imports and returns machine code that can be executed by a virtual machine.
 * @param {string} mainModulePath - The main file path.
 * @returns {Promise<Program>} The resulting machine code, symbols, structs, and exports.
 */
export const assemble = async (
  mainModulePath: string,
  offset = 0
): Promise<Program> => {
  try {
    const res = await fetch(mainModulePath)
    const mainFileString = await res.text()
    return processModule(mainFileString.trim(), offset)
  } catch (err) {
    console.error(err)
    throw new Error(`Failed to assemble module '${mainModulePath}'`)
  }
}

/**
 * `assembleString` parses a module string and returns machine code that can be executed by a virtual machine.
 * @param program The program string to be assembled.
 * @returns {Module} The resulting machine code, symbols, structs, and exports.
 */
export const assembleString = (program: string, offset = 0): Program =>
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
