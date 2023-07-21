import { ANSI_COLOR_RESET } from './util'

export const logWithFormat = (msg: string, ...ANSICodes: Array<string>) => {
  ANSICodes.forEach((c) => process.stdout.write(c))
  process.stdout.write(msg)
  process.stdout.write(ANSI_COLOR_RESET)
}
