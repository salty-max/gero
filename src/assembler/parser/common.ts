import P from 'parsil'
import { REGISTER_NAMES } from '../../util'
import { mapJoin } from './util'
import {
  addressNode,
  hexLiteralNode,
  opMinus,
  opMultiply,
  opPlus,
  registerNode,
  variableNode,
} from './types'

export const upperOrLowerStr = (s: string) =>
  P.choice([P.str(s.toUpperCase()), P.str(s.toLowerCase())])

const registerParserArray = REGISTER_NAMES.map((r) => upperOrLowerStr(r))

export const register = P.choice(registerParserArray).map(registerNode)

export const hexDigit = P.regex(/^[0-9A-Fa-f]/)

export const hexLiteral = P.char('$')
  .chain(() => mapJoin(P.manyOne(hexDigit)))
  .map(hexLiteralNode)

export const address = P.char('&')
  .chain(() => mapJoin(P.manyOne(hexDigit)))
  .map(addressNode)

export const validIdentifier = mapJoin(
  P.sequenceOf([
    P.regex(/^[a-zA-Z_]/),
    P.possibly(P.regex(/^[a-zA-Z0-9_]+/)).map((x) => (x === null ? '' : x)),
  ])
)

export const variable = P.char('!')
  .chain(() => validIdentifier)
  .map(variableNode)

export const operator = P.choice([
  P.char('+').map(opPlus),
  P.char('-').map(opMinus),
  P.char('*').map(opMultiply),
])
