import * as P from 'parsil'
import T from './types'
import { upperOrLowerStr, hexLiteral, register, address } from './common'
import { bracketExpr } from './expressions'

export const noArgs = (mnemonic: string, type: string) =>
  P.coroutine((run) => {
    run(upperOrLowerStr(mnemonic))
    run(P.optionalWhitespace)

    return T.instructionNode({
      instruction: type,
      args: [],
    })
  })

export const singleReg = (mnemonic: string, type: string) =>
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

export const singleLit = (mnemonic: string, type: string) =>
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

export const singleAddr = (mnemonic: string, type: string) =>
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

export const litReg = (mnemonic: string, type: string) =>
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

export const regReg = (mnemonic: string, type: string) =>
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

export const regMem = (mnemonic: string, type: string) =>
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

export const regLit = (mnemonic: string, type: string) =>
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

export const memReg = (mnemonic: string, type: string) =>
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

export const litMem = (mnemonic: string, type: string) =>
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

export const regPtrReg = (mnemonic: string, type: string) =>
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

export const regRegPtr = (mnemonic: string, type: string) =>
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

export const litOffReg = (mnemonic: string, type: string) =>
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
