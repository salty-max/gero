/**
 * @file memory.ts
 */

export interface Memory {
  ab: ArrayBuffer
  load: (data: number[]) => void
  slice: (from: number, to: number) => Uint8Array
  getUint8: (offset: number, littleEndian?: boolean) => number
  getUint16: (offset: number, littleEndian?: boolean) => number
  setUint8: (offset: number, value: number, littleEndian?: boolean) => void
  setUint16: (offset: number, value: number, littleEndian?: boolean) => void
}

/**
 * Creates a new RAM memory with the specified size.
 * @param sizeInBytes - The size of the ArrayBuffer in bytes.
 * @returns - A RAM object.
 */
export const createRAM = (sizeInBytes: number): Memory => {
  const ab = new ArrayBuffer(sizeInBytes)
  const dv = new DataView(ab)
  const bytes = new Uint8Array(ab)

  return {
    ab,
    load: (data: number[]) => data.forEach((d, i) => dv.setUint8(i, d)),
    slice: (from: number, to: number) => bytes.slice(from, to),
    getUint8: dv.getUint8.bind(dv),
    getUint16: dv.getUint16.bind(dv),
    setUint8: dv.setUint8.bind(dv),
    setUint16: dv.setUint16.bind(dv),
  }
}

/**
 * Creates a new ROM memory with the specified size.
 * @param sizeInBytes - The size of the ArrayBuffer in bytes.
 * @returns - A ROM object.
 */
export const createROM = (sizeInBytes: number): Memory => {
  const ab = new ArrayBuffer(sizeInBytes)
  const dv = new DataView(ab)
  const bytes = new Uint8Array(ab)

  return {
    ab,
    load: (data: number[]) => data.forEach((d, i) => dv.setUint8(i, d)),
    slice: (from: number, to: number) => bytes.slice(from, to),
    getUint8: dv.getUint8.bind(dv),
    getUint16: dv.getUint16.bind(dv),
    setUint8: () => 0,
    setUint16: () => 0,
  }
}
