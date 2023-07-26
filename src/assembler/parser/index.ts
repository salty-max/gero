import { label } from './common'
import { constant } from './constant'
import { data16, data8 } from './data'
import instructions from './instructions'
import * as P from 'parsil'
import { struct } from './struct'
import { comment } from './comment'

export default P.many(
  P.choice([instructions, label, data8, data16, constant, struct, comment])
).chain((res) => P.endOfInput.map(() => res))
