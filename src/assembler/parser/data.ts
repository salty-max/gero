import * as P from 'parsil'
import { commaSeparated, hexLiteral, validIdentifier } from './common'
import T from './types'

const dataParser = (size: number) =>
  P.coroutine((run) => {
    const isExport = Boolean(run(P.possibly(P.char('+'))))

    run(P.str(`data${size}`))
    run(P.whitespace)

    const name = run(validIdentifier)
    run(P.whitespace)
    run(P.char('='))
    run(P.whitespace)
    run(P.char('{'))
    run(P.optionalWhitespace)

    const values = run(commaSeparated(hexLiteral))

    run(P.optionalWhitespace)
    run(P.char('}'))
    run(P.optionalWhitespace)

    return T.dataNode({
      size,
      isExport,
      name,
      values,
    })
  })

export const data8 = dataParser(8)
export const data16 = dataParser(16)
