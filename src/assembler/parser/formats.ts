import * as P from 'parsil'
import T from './types'
import { upperOrLowerStr, hexLiteral, register, address } from './common'
import { bracketExpr } from './expressions'

export type FormatParser = (mnemonic: string, type: string) => P.Parser<any>

const noArgs = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [],
    })
  })

const singleReg = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const reg = run(register)
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [reg],
    })
  })

const singleLit = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)
    const lit = run(P.choice([hexLiteral, bracketExpr]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [lit],
    })
  })

const singleAddr = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const addr = run(P.choice([address, P.char('&').chain(() => bracketExpr)]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [addr],
    })
  })

const litReg = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const reg = run(register)
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [lit, reg],
    })
  })

const regReg = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const r1 = run(register)

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const r2 = run(register)
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [r1, r2],
    })
  })

const regMem = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const reg = run(register)

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const addr = run(P.choice([address, P.char('&').chain(() => bracketExpr)]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [reg, addr],
    })
  })

const regLit = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const reg = run(register)

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [reg, lit],
    })
  })

const regLit8 = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const reg = run(register)

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [reg, lit],
    })
  })

const memReg = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const addr = run(P.choice([address, P.char('&').chain(() => bracketExpr)]))
    run(P.optionalWhitespace)

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const rTo = run(register)
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [addr, rTo],
    })
  })

const litMem = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const addr = run(P.choice([address, P.char('&').chain(() => bracketExpr)]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [lit, addr],
    })
  })

const litMem8 = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const addr = run(P.choice([address, P.char('&').chain(() => bracketExpr)]))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [lit, addr],
    })
  })

const regPtrReg = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const rFrom = run(P.char('&').chain(() => register))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const rTo = run(register)
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [rFrom, rTo],
    })
  })

const regRegPtr = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const rFrom = run(register)

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const rTo = run(P.char('&').chain(() => register))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [rFrom, rTo],
    })
  })

const litOffReg = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const rFrom = run(P.char('&').chain(() => register))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const rTo = run(register)
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [lit, rFrom, rTo],
    })
  })

const litRegPtr = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.whitespace)

    const lit = run(P.choice([hexLiteral, bracketExpr]))

    run(P.optionalWhitespace)
    run(P.char(','))
    run(P.optionalWhitespace)

    const ptr = run(P.char('&').chain(() => register))

    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [lit, ptr],
    })
  })

const F: Record<string, FormatParser> = {
  noArgs,
  singleReg,
  singleLit,
  singleAddr,
  litReg,
  regReg,
  regMem,
  regLit,
  regLit8,
  memReg,
  litMem,
  litMem8,
  regPtrReg,
  regRegPtr,
  litRegPtr,
  litOffReg,
}

export default F
