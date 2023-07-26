import * as P from 'parsil'
import T from './types'
import { hexLiteral, validIdentifier } from './common'
import { bracketExpr } from './expressions'

export const constant = P.coroutine((run) => {
  const isExport = Boolean(run(P.possibly(P.char('+'))))
  run(P.str('constant'))
  run(P.whitespace)

  const name = run(validIdentifier)

  run(P.whitespace)
  run(P.char('='))
  run(P.whitespace)

  const value = run(P.choice([hexLiteral, bracketExpr]))
  run(P.optionalWhitespace)

  return T.constantNode({
    isExport,
    name,
    value,
  })
})
