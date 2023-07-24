import * as P from 'parsil'
import { REGISTER_NAMES } from '../../util'
import { mapJoin } from './util'
import T from './types'

const upperOrLowerStr = (s: string) =>
  P.choice([P.str(s.toUpperCase()), P.str(s.toLowerCase())])

const optionalWhitespaceSurrounded = P.between(
  P.optionalWhitespace,
  P.optionalWhitespace
)

const commaSeparated = P.sepBy(optionalWhitespaceSurrounded(P.char(',')))

const register = P.choice(REGISTER_NAMES.map(upperOrLowerStr)).map(
  T.registerNode
)

const hexDigit = P.regex(/^[0-9A-Fa-f]/)

const hexLiteral = P.char('$')
  .chain(() => mapJoin(P.manyOne(hexDigit)))
  .map(T.hexLiteralNode)

const address = P.char('&')
  .chain(() => mapJoin(P.manyOne(hexDigit)))
  .map(T.addressNode)

const validIdentifier = mapJoin(
  P.sequenceOf([
    P.regex(/^[a-zA-Z_]/),
    P.possibly(P.regex(/^[a-zA-Z0-9_]+/)).map((x) => (x === null ? '' : x)),
  ])
)

const variable = P.char('!')
  .chain(() => validIdentifier)
  .map(T.variableNode)

const operator = P.choice([
  P.char('+').map(T.opPlus),
  P.char('-').map(T.opMinus),
  P.char('*').map(T.opMultiply),
])

const label = P.sequenceOf([validIdentifier, P.char(':'), P.optionalWhitespace])
  .map(([label]) => label)
  .map(T.labelNode)

export {
  upperOrLowerStr,
  optionalWhitespaceSurrounded,
  commaSeparated,
  register,
  hexDigit,
  hexLiteral,
  address,
  validIdentifier,
  variable,
  operator,
  label,
}
