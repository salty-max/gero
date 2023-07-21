import { Parser } from 'parsil'
import { inspect } from 'util'

export const deepLog = (x: unknown) =>
  console.log(
    inspect(x, {
      depth: Infinity,
      colors: true,
    })
  )

export const asType = (type: string) => (value: unknown) => ({ type, value })

export const mapJoin = (parser: Parser<string[]>) =>
  parser.map((items) => items.join(''))

export const last = <T>(a: T[]) => a[a.length - 1]

export const typifyGroupedExpr = (expr: any) => {
  const asGrouped = asType('GROUPED_EXPRESSION')
  return asGrouped(
    expr.map((el: any) => {
      if (Array.isArray(el)) {
        return typifyGroupedExpr(el)
      }

      return el
    })
  )
}
