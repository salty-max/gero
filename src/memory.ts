/**
 * @file memory.ts
 */

/**
 * Creates a new DataView instance with the specified size.
 *
 * @export
 * @param {number} sizeInBytes - The size of the ArrayBuffer in bytes.
 * @returns {DataView} A DataView instance.
 *
 * @example
 * const memory = createMemory(1024); // Creates a new DataView with 1024 bytes.
 */
export const createMemory = (sizeInBytes: number) => {
  const ab = new ArrayBuffer(sizeInBytes)
  const dv = new DataView(ab)

  return dv
}
