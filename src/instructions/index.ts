import { meta, IMeta, instructionTypes } from './meta'

const indexBy = (array: Array<IMeta>, prop: string) =>
  array.reduce((output: Record<string, IMeta>, item: IMeta) => {
    output[item[prop as keyof IMeta]] = item
    return output
  }, {})

export { instructionTypes }
export default indexBy(meta, 'instruction')
