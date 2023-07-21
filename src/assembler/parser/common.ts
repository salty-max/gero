import P, { Parser } from 'parsil'
import { REGISTER_NAMES } from '../../util'
import { mapJoin } from './util'
import {
  hexLiteralType,
  opMinus,
  opMultiply,
  opPlus,
  registerType,
  variableType,
} from './types'

const registerParserArray = REGISTER_NAMES.map((r) => upperOrLowerStr(r)) as [
  Parser<string>,
]

export const upperOrLowerStr = (s: string) =>
  P.choice([P.str(s.toUpperCase()), P.str(s.toLowerCase())])

export const register = P.choice(registerParserArray).map(registerType)

export const hexDigit = P.regex(/^[0-9A-Fa-f]/)

export const hexLiteral = P.char('$')
  .chain(() => mapJoin(P.manyOne(hexDigit)))
  .map(hexLiteralType)

export const validIdentifier = mapJoin(
  P.sequenceOf([
    P.regex(/^[a-zA-Z_]/),
    P.possibly(P.regex(/^[a-zA-Z0-9_]+/)).map((x) => (x === null ? '' : x)),
  ])
)

export const variable = P.char('!')
  .chain(() => validIdentifier)
  .map(variableType)

export const operator = P.choice([
  P.char('+').map(opPlus),
  P.char('-').map(opMinus),
  P.char('*').map(opMultiply),
])
