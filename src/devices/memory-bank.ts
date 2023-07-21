// Importing required modules
import { CPU, Device } from '../vm'

/**
 * The `MemoryBankDevice` interface extends the `Device` interface.
 */
interface MemoryBankDevice extends Device {}

// Defines the size of each memory bank and the total number of banks.
export const BANK_SIZE = 0xff
export const BANKS_COUNT = 8

// Defines the array of method names that will be used as getters from a DataView object.
const getterMethods: (keyof DataViewGetters)[] = ['getUint8', 'getUint16']

// Defines the array of method names that will be used as setters for a DataView object.
const setterMethods: (keyof DataViewSetters)[] = ['setUint8', 'setUint16']

/**
 * DataViewGetters interface defines methods for getting data from a DataView object.
 * getUint8: Method to get a 8-bit unsigned integer at the specified byte offset from the start of the DataView.
 * getUint16: Method to get a 16-bit unsigned integer (unsigned short) at the specified byte offset from the start of the DataView.
 */
interface DataViewGetters {
  getUint8: (...args: [number, boolean?]) => number
  getUint16: (...args: [number, boolean?]) => number
}

/**
 * DataViewSetters interface defines methods for setting data in a DataView object.
 * setUint8: Method to set a 8-bit unsigned integer at the specified byte offset from the start of the DataView.
 * setUint16: Method to set a 16-bit unsigned integer (unsigned short) at the specified byte offset from the start of the DataView.
 */
interface DataViewSetters {
  setUint8: (...args: [number, number, boolean?]) => void
  setUint16: (...args: [number, number, boolean?]) => void
}

// CustomDataView is a combination of DataViewGetters and DataViewSetters interfaces.
type CustomDataView = DataViewGetters & DataViewSetters

/**
 * The createBankedMemory function creates a memory bank device.
 * It takes the number of banks (n), size of each bank (bankSize), and a CPU object as parameters.
 * @param n - Number of memory banks
 * @param bankSize - Size of each memory bank
 * @param cpu - CPU object used to interact with memory banks
 * @returns MemoryBankDevice interface which provides get and set operations to the memory banks
 */
export const createBankedMemory = (
  n: number,
  bankSize: number,
  cpu: CPU
): MemoryBankDevice => {
  // Creates an array of ArrayBuffers (the "banks") each with a size of 'bankSize'
  const bankBuffers = Array.from({ length: n }, () => new ArrayBuffer(bankSize))

  // Creates a DataView for each ArrayBuffer
  const banks = bankBuffers.map((ab) => new DataView(ab))

  // Functions to access the current memory bank and invoke a getter or setter method on it
  const forwardToDataViewGetter = (
    methodName: keyof DataViewGetters,
    ...args: any[]
  ): number => {
    const bankIndex = cpu.getRegister('mb') % n // determines the current memory bank
    const memoryBank = banks[bankIndex] // accesses the memory bank
    return (memoryBank as any)[methodName](...args) as number // invokes the getter method on the memory bank
  }

  const forwardToDataViewSetter = (
    methodName: keyof DataViewSetters,
    ...args: any[]
  ): void => {
    const bankIndex = cpu.getRegister('mb') % n // determines the current memory bank
    const memoryBank = banks[bankIndex] // accesses the memory bank
    ;(memoryBank as any)[methodName](...args) as void // invokes the setter method on the memory bank
  }

  // Creates getter and setter objects by reducing over the arrays of method names
  const getters: DataViewGetters = getterMethods.reduce(
    (dvOut: Partial<DataViewGetters>, methodName) => {
      dvOut[methodName] = (...args) =>
        forwardToDataViewGetter(methodName, ...args)
      return dvOut
    },
    {} as Partial<DataViewGetters>
  ) as DataViewGetters

  const setters: DataViewSetters = setterMethods.reduce(
    (dvOut: Partial<DataViewSetters>, methodName) => {
      dvOut[methodName] = (...args) =>
        forwardToDataViewSetter(methodName, ...args)
      return dvOut
    },
    {} as Partial<DataViewSetters>
  ) as DataViewSetters

  // Combines the getters and setters into a single object
  const dataViewInterface: CustomDataView = { ...getters, ...setters }

  // Returns the interface which provides get and set operations to the memory banks
  return dataViewInterface
}
