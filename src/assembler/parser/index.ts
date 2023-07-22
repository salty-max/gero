import { label } from './common'
import { constant } from './constant'
import { data16, data8 } from './data'
import instructions from './instructions'
import P from 'parsil'

export default P.many(P.choice([instructions, label, data8, data16, constant]))
