import { asType } from './util'

export type Node = {
  type: string
  value: any
}

export const instructionNode = asType('INSTRUCTION')
export const registerNode = asType('REGISTER')
export const hexLiteralNode = asType('HEX_LITERAL')
export const addressNode = asType('ADDRESS')
export const variableNode = asType('VARIABLE')

export const opPlus = asType('OP_PLUS')
export const opMinus = asType('OP_MINUS')
export const opMultiply = asType('OP_MULTIPLY')

export const binaryOperationNode = asType('BINARY_OPERATION')
export const groupedExprNode = asType('GROUPED_EXPRESSION')
export const bracketExprNode = asType('SQUARE_BRACKET_EXPRESSION')
