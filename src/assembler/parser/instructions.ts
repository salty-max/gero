import * as P from 'parsil'
import F, { FormatParser } from './formats'
import { instructionTypes, meta } from '../../instructions/meta'

const typeFormats = Object.entries(instructionTypes).reduce(
  (table, [type, value]) => {
    table[value] = F[type]
    return table
  },
  {} as Record<string, FormatParser>
)

const allInstructions = meta.map((instruction) => {
  if (!(instruction.type in typeFormats)) {
    throw new Error(`Unknown instruction format: ${instruction.type}`)
  }

  return typeFormats[instruction.type](
    instruction.mnemonic,
    instruction.instruction
  )
})

console.log(allInstructions)

export default P.choice(allInstructions)
