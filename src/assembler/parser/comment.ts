import * as P from 'parsil'
import T from './types'
import { bytesToString } from './common'

export const comment = P.coroutine((run) => {
  run(P.optionalWhitespace)
  run(P.exactly(2)(P.char(';')))
  run(P.optionalWhitespace)
  const value = run(P.everythingUntil(P.char('\n')).map(bytesToString))
  run(P.optionalWhitespace)
  return T.commentNode({ value })
})
