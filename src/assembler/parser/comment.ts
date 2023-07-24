import * as P from 'parsil'
import T from './types'

const bytesToString = (bytes: number[]) =>
  bytes.map((b) => String.fromCharCode(b)).join('')

export const comment = P.coroutine((run) => {
  run(P.optionalWhitespace)
  run(P.char('#'))
  run(P.optionalWhitespace)
  const value = run(P.everythingUntil(P.char('\n')).map(bytesToString))
  run(P.optionalWhitespace)

  return T.commentNode({ value })
})
