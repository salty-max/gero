import P from 'parsil'
import T from './types'
import { commaSeparated, hexLiteral, validIdentifier } from './common'

const keyValuePair = P.coroutine((run) => {
  run(P.optionalWhitespace)
  const key = run(validIdentifier)
  run(P.optionalWhitespace)
  run(P.char(':'))
  run(P.optionalWhitespace)
  const value = run(hexLiteral)
  run(P.optionalWhitespace)

  return { key, value }
})

export const struct = P.coroutine((run) => {
  const isExport = Boolean(run(P.possibly(P.char('+'))))

  run(P.str('struct'))
  run(P.whitespace)
  const name = run(validIdentifier)
  run(P.whitespace)
  run(P.char('{'))
  run(P.optionalWhitespace)
  const members = run(commaSeparated(keyValuePair))
  run(P.optionalWhitespace)
  run(P.char('}'))
  run(P.optionalWhitespace)

  return T.structNode({
    isExport,
    name,
    members,
  })
})
