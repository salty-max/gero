import P from 'parsil'
import T from './types'
import {
  commaSeparated,
  hexLiteral,
  optionalWhitespaceSurrounded,
  validIdentifier,
} from './common'

const keyword = (kw: string) =>
  P.str(kw)
    .chain(() => P.whitespace)
    .map(() => kw)

const stringLiteral = P.coroutine((run) => {
  run(P.char('"'))

  const chars = run(
    P.many(P.choice([P.str('\\"'), P.anyCharExcept(P.char('"'))]))
  )

  run(P.char('"'))

  return chars.join('')
})

const moduleExportPath = P.coroutine((run) => {
  run(optionalWhitespaceSurrounded(P.char('[')))

  const parts = []
  while (true) {
    const pathPart = run(validIdentifier)
    const possibleDot = run(P.possibly(P.char('.')))
    if (!possibleDot) {
      break
    }
    parts.push(pathPart)
  }

  run(optionalWhitespaceSurrounded(P.char(']')))
  return T.moduleExportPathNode(parts.join('.'))
})

const injectionEntry = P.coroutine((run) => {
  const name = run(optionalWhitespaceSurrounded(validIdentifier))
  run(optionalWhitespaceSurrounded(P.char(':')))
  const value = run(P.choice([hexLiteral, moduleExportPath]))
  run(P.optionalWhitespace)

  return { name, value }
})

const injections = P.coroutine((run) => {
  run(P.optionalWhitespace)

  run(P.char('{'))
  run(P.optionalWhitespace)
  const values = run(commaSeparated(injectionEntry))
  run(P.optionalWhitespace)
  run(P.char('}'))
  run(P.optionalWhitespace)

  return values
})

const importDeclaration = P.coroutine((run) => {
  run(P.optionalWhitespace)
  run(keyword('import'))

  const name = run(validIdentifier)
  run(P.whitespace)

  const targetAddress = run(hexLiteral)
  run(P.whitespace)

  const path = run(stringLiteral)
  run(P.whitespace)

  const injectionValues = run(injections)

  return T.importDeclarationNode({
    name,
    targetAddress,
    path,
    injectionValues,
  })
})

export const topLevelModule = P.coroutine((run) => {
  run(P.optionalWhitespace)
  run(keyword('module'))

  const name = run(validIdentifier)
  run(P.whitespace)

  const imports = []
  while (true) {
    const possibleImport = run(P.possibly(importDeclaration))
    if (!possibleImport) {
      break
    }
    imports.push(possibleImport)

    const ws = run(P.possibly(P.whitespace))
    if (!ws) {
      break
    }
  }

  return T.topLevelModuleNode({
    name,
    imports,
  })
})
