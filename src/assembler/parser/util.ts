import { Parser, ResultType, isOk } from 'parsil'

export const deepLog = (x: any) => console.log(JSON.stringify(x, null, 2))

export const asType = (type: string) => (value: any) => ({ type, value })

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

export const parserResult = (res: ResultType<any, any>) => {
  if (isOk(res)) {
    return res
  } else {
    throw new Error(res.error)
  }
}

export function readFileAsync(file: File) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()

    reader.onload = () => {
      resolve(reader.result)
    }

    reader.onerror = reject

    reader.readAsText(file)
  })
}
