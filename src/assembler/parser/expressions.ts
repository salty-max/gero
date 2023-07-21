import P from 'parsil'
import { last, typifyGroupedExpr } from './util'
import {
  binaryOperationNode,
  bracketExprNode,
  groupedExprNode,
  Node,
} from './types'
import { hexLiteral, operator, variable } from './common'

const handleOperatorPrecedence = (expr: Node): Node => {
  if (
    !['SQUARE_BRACKET_EXPRESSION', 'GROUPED_EXPRESSION'].includes(expr.type)
  ) {
    return expr
  }

  if (expr.value.length === 1) {
    return expr.value[0]
  }

  const priorities: Record<string, number> = {
    OP_MULTIPLY: 2,
    OP_PLUS: 1,
    OP_MINUS: 0,
  }

  let candidateExpr: {
    priority: number
    a: any
    b: any
    op: Node | null
  } = {
    priority: -Infinity,
    a: null,
    b: null,
    op: null,
  }

  for (let i = 1; i < expr.value.length; i += 2) {
    const level = priorities[expr.value[i].type]
    if (level > candidateExpr.priority) {
      candidateExpr = {
        priority: level,
        a: i - 1,
        b: i + 1,
        op: expr.value[i],
      }
    }
  }

  const newExpr = groupedExprNode([
    ...expr.value.slice(0, candidateExpr),
    binaryOperationNode({
      a: handleOperatorPrecedence(expr.value[candidateExpr.a]),
      b: handleOperatorPrecedence(expr.value[candidateExpr.b]),
      op: candidateExpr.op,
    }),
    ...expr.value.slice(candidateExpr.b + 1),
  ])

  return handleOperatorPrecedence(newExpr)
}

export const groupedExpr = P.coroutine((run) => {
  enum State {
    OPEN_PAREN,
    ELEMENT_OR_OPENING_PAREN,
    OPERATOR_OR_CLOSING_PAREN,
    CLOSE_PAREN,
  }

  let state = State.ELEMENT_OR_OPENING_PAREN
  const expr: any[] = []
  const stack: any[] = [expr]
  run(P.char('('))

  while (stack.length > 0) {
    const nextChar = run(P.peek)

    switch (state) {
      case State.OPEN_PAREN:
        run(P.char('('))
        expr.push([])
        stack.push(last(expr))
        run(P.optionalWhitespace)
        state = State.ELEMENT_OR_OPENING_PAREN
        break
      case State.CLOSE_PAREN:
        run(P.char(')'))
        stack.pop()
        if (stack.length === 0) {
          // End of the paren expression
          break
        }

        run(P.optionalWhitespace)
        state = State.OPERATOR_OR_CLOSING_PAREN
        break
      case State.ELEMENT_OR_OPENING_PAREN:
        if (nextChar === ')'.charCodeAt(0)) {
          run(P.fail('Unexpected end of expresssion'))
        }

        if (nextChar === '('.charCodeAt(0)) {
          state = State.OPEN_PAREN
        } else {
          last(stack).push(run(P.choice([hexLiteral, variable])))
          run(P.optionalWhitespace)
          state = State.OPERATOR_OR_CLOSING_PAREN
        }
        break
      case State.OPERATOR_OR_CLOSING_PAREN:
        if (nextChar === ')'.charCodeAt(0)) {
          state = State.CLOSE_PAREN
          continue
        }

        last(stack).push(run(operator))
        run(P.optionalWhitespace)
        state = State.ELEMENT_OR_OPENING_PAREN
        break
      default:
        throw new Error('parenExpr: Unknown state')
    }
  }

  return typifyGroupedExpr(expr)
})

export const bracketExpr = P.coroutine((run) => {
  run(P.char('['))
  run(P.optionalWhitespace)

  enum State {
    EXPECT_ELEMENT,
    EXPECT_OPERATOR,
  }

  const expr = []
  let state = State.EXPECT_ELEMENT

  while (true) {
    if (state === State.EXPECT_ELEMENT) {
      const result = run(P.choice([groupedExpr, hexLiteral, variable]))
      expr.push(result)
      state = State.EXPECT_OPERATOR
      run(P.optionalWhitespace)
    } else if (state === State.EXPECT_OPERATOR) {
      const nextChar = run(P.peek)

      if (nextChar === ']'.charCodeAt(0)) {
        run(P.char(']'))
        run(P.optionalWhitespace)
        break
      }

      const result = run(operator)
      expr.push(result)
      state = State.EXPECT_ELEMENT
      run(P.optionalWhitespace)
    }
  }

  return bracketExprNode(expr)
}).map(handleOperatorPrecedence)
