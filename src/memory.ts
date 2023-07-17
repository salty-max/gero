export const createMemory = (sizeInBytes: number) => {
  const ab = new ArrayBuffer(sizeInBytes)
  const dv = new DataView(ab)

  return dv
}
