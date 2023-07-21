import { asType } from './util'

export type Node = {
  type: string
  value: any
}

export const instructionType = asType('INSTRUCTION')
export const registerType = asType('REGISTER')
export const hexLiteralType = asType('HEX_LITERAL')
export const variableType = asType('VARIABLE')

export const opPlus = asType('OP_PLUS')
export const opMinus = asType('OP_MINUS')
export const opMultiply = asType('OP_MULTIPLY')

export const binaryOperation = asType('BINARY_OPERATION')
export const groupedExprType = asType('GROUPED_EXPRESSION')
export const bracketExprType = asType('SQUARE_BRACKET_EXPRESSION')
