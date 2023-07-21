import P from 'parsil'
import { instructionType } from './types'
import { deepLog } from './util'
import { upperOrLowerStr, hexLiteral, register } from './common'
import { bracketExpr } from './expressions'

const movLitToReg = P.coroutine((run) => {
  run(upperOrLowerStr('mov'))
  run(P.whitespace)

  const arg1 = run(P.choice([hexLiteral, bracketExpr]))

  run(P.optionalWhitespace)
  run(P.char(','))
  run(P.optionalWhitespace)

  const arg2 = run(register)
  run(P.optionalWhitespace)

  return instructionType({
    instruction: 'MOV_LIT_REG',
    args: [arg1, arg2],
  })
})

const res = movLitToReg.run('mov [$42 + !loc - ($05 * ($31 + !var) - $07)], r4')
deepLog(res)
