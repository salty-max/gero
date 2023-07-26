import * as P from 'parsil'
import T from './types'
import { address, validIdentifier } from './common'

export const interpretAs = P.coroutine((run) => {
  run(P.char('<'))
  run(P.optionalWhitespace)
  const struct = run(validIdentifier)
  run(P.optionalWhitespace)
  run(P.char('>'))
  run(P.optionalWhitespace)
  const symbol = run(P.choice([validIdentifier, address]))
  run(P.char('.'))
  const property = run(validIdentifier)
  run(P.optionalWhitespace)

  return T.interpretAsNode({
    struct,
    symbol,
    property,
  })
})
