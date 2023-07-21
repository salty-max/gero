import { label } from './common'
import instructions from './instructions'
import P from 'parsil'

export default P.many(P.choice([instructions, label]))
