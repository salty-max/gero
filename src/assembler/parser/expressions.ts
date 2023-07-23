import * as P from 'parsil'
import { last, typifyGroupedExpr } from './util'
import T, { Node } from './types'
import { hexLiteral, operator, variable } from './common'
import { interpretAs } from './interpret-as'

const expression = P.choice([hexLiteral, variable, interpretAs])

// Function to handle operator precedence in a given expression
const handleOperatorPrecedence = (expr: Node): Node => {
  // If the expression is not a grouped expression or square bracket expression, return it as it is
  if (
    !['SQUARE_BRACKET_EXPRESSION', 'GROUPED_EXPRESSION'].includes(expr.type)
  ) {
    return expr
  }

  // If the expression contains only one element, return that element
  if (expr.value.length === 1) {
    return expr.value[0]
  }

  // Define the priorities of operators
  const priorities: Record<string, number> = {
    OP_MULTIPLY: 2,
    OP_PLUS: 1,
    OP_MINUS: 0,
  }

  // Initialize a candidate expression object with a low priority
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

  // Find the operator with the highest priority in the expression
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

  // Create a new expression with the highest priority operation replaced by the result of that operation
  const newExpr = T.groupedExprNode([
    ...expr.value.slice(0, candidateExpr),
    T.binaryOperationNode({
      a: handleOperatorPrecedence(expr.value[candidateExpr.a]),
      b: handleOperatorPrecedence(expr.value[candidateExpr.b]),
      op: candidateExpr.op,
    }),
    ...expr.value.slice(candidateExpr.b + 1),
  ])

  // Continue handling operator precedence in the new expression recursively
  return handleOperatorPrecedence(newExpr)
}

// Define the grammar for parsing grouped expressions
export const groupedExpr = P.coroutine((run) => {
  // Define possible states during parsing
  enum State {
    OPEN_PAREN,
    ELEMENT_OR_OPENING_PAREN,
    OPERATOR_OR_CLOSING_PAREN,
    CLOSE_PAREN,
  }

  // Initialize the parser state and expression array
  let state = State.ELEMENT_OR_OPENING_PAREN
  const expr: any[] = []
  const stack: any[] = [expr]
  run(P.char('('))

  while (stack.length > 0) {
    // Look at the next character in the input
    const nextChar = run(P.peek)

    switch (state) {
      case State.OPEN_PAREN:
        // Handle an opening parenthesis by creating a new nested expression
        run(P.char('('))
        expr.push([])
        stack.push(last(expr))
        run(P.optionalWhitespace)
        state = State.ELEMENT_OR_OPENING_PAREN
        break
      case State.CLOSE_PAREN:
        // Handle a closing parenthesis by popping the current nested expression from the stack
        run(P.char(')'))
        stack.pop()
        if (stack.length === 0) {
          // End of the top-level grouped expression
          break
        }

        run(P.optionalWhitespace)
        state = State.OPERATOR_OR_CLOSING_PAREN
        break
      case State.ELEMENT_OR_OPENING_PAREN:
        // Determine whether the next element is an operand or an opening parenthesis
        if (nextChar === ')'.charCodeAt(0)) {
          run(P.fail('Unexpected end of expression'))
        }

        if (nextChar === '('.charCodeAt(0)) {
          state = State.OPEN_PAREN
        } else {
          // Parse the element (operand) and move to the state of expecting an operator or closing parenthesis
          last(stack).push(run(expression))
          run(P.optionalWhitespace)
          state = State.OPERATOR_OR_CLOSING_PAREN
        }
        break
      case State.OPERATOR_OR_CLOSING_PAREN:
        // Determine whether the next element is an operator or a closing parenthesis
        if (nextChar === ')'.charCodeAt(0)) {
          state = State.CLOSE_PAREN
          continue
        }

        // Parse the operator and move to the state of expecting an element or opening parenthesis
        last(stack).push(run(operator))
        run(P.optionalWhitespace)
        state = State.ELEMENT_OR_OPENING_PAREN
        break
      default:
        throw new Error('parenExpr: Unknown state')
    }
  }

  // Return the parsed grouped expression after applying type inference to the expression
  return typifyGroupedExpr(expr)
})

// Define the grammar for parsing square bracket expressions
export const bracketExpr = P.coroutine((run) => {
  run(P.char('['))
  run(P.optionalWhitespace)

  // Define possible states during parsing
  enum State {
    EXPECT_ELEMENT,
    EXPECT_OPERATOR,
  }

  // Initialize the expression array and state
  const expr = []
  let state = State.EXPECT_ELEMENT

  while (true) {
    if (state === State.EXPECT_ELEMENT) {
      // Parse the element (operand) and move to the state of expecting an operator
      const result = run(P.choice([groupedExpr, expression]))
      expr.push(result)
      state = State.EXPECT_OPERATOR
      run(P.optionalWhitespace)
    } else if (state === State.EXPECT_OPERATOR) {
      // Look at the next character in the input
      const nextChar = run(P.peek)

      if (nextChar === ']'.charCodeAt(0)) {
        // Handle the closing square bracket by ending the square bracket expression
        run(P.char(']'))
        run(P.optionalWhitespace)
        break
      }

      // Parse the operator and move to the state of expecting an element
      const result = run(operator)
      expr.push(result)
      state = State.EXPECT_ELEMENT
      run(P.optionalWhitespace)
    }
  }

  // Return the parsed square bracket expression after applying operator precedence handling
  return T.bracketExprNode(expr)
}).map(handleOperatorPrecedence)
