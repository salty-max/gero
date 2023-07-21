import { meta, IMeta, InstructionType } from './meta'

const indexBy = (array: Array<IMeta>, prop: string) =>
  array.reduce((output: Record<string, IMeta>, item: IMeta) => {
    output[item[prop as keyof IMeta]] = item
    return output
  }, {})

export { InstructionType }
export default indexBy(meta, 'instruction')
