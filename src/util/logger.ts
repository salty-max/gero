import { ANSI_COLOR_RESET } from './util'

export const logWithFormat = (msg: string, ...ANSICodes: Array<string>) => {
  ANSICodes.forEach((c) => console.log(c))
  console.log(msg)
  console.log(ANSI_COLOR_RESET)
}
