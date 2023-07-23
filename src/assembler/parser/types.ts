import { asType } from './util'

export type Node = {
  type: string
  value: any
}

export type Member = {
  offset: number
  size: number
}

export type Struct = {
  members: Record<string, Member>
}

export type Export = {
  type: string
  value: string
}

export type Module = {
  machineCode: number[]
  symbols: Record<string, number>
  exports: Record<string, Export>
  structs: Record<string, Struct>
}

export type Program = {
  machineCode: number[]
  symbols: Record<string, number>
}

const instructionNode = asType('INSTRUCTION')
const registerNode = asType('REGISTER')
const hexLiteralNode = asType('HEX_LITERAL')
const addressNode = asType('ADDRESS')
const variableNode = asType('VARIABLE')
const labelNode = asType('LABEL')

const opPlus = asType('OP_PLUS')
const opMinus = asType('OP_MINUS')
const opMultiply = asType('OP_MULTIPLY')

const binaryOperationNode = asType('BINARY_OPERATION')
const groupedExprNode = asType('GROUPED_EXPRESSION')
const bracketExprNode = asType('SQUARE_BRACKET_EXPRESSION')

const dataNode = asType('DATA')
const constantNode = asType('CONSTANT')
const structNode = asType('STRUCT')
const interpretAsNode = asType('INTERPRET_AS')

export default {
  instructionNode,
  registerNode,
  hexLiteralNode,
  addressNode,
  variableNode,
  labelNode,
  opPlus,
  opMinus,
  opMultiply,
  binaryOperationNode,
  groupedExprNode,
  bracketExprNode,
  dataNode,
  constantNode,
  structNode,
  interpretAsNode,
}
