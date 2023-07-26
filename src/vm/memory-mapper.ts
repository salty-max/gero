/**
 * This file provides the classes and interfaces for memory mapping operations in our assembly interpreter.
 * It defines the `Device` interface, the `Region` interface, and the `MemoryMapper` class.
 *
 * `Device` describes the methods that a memory device must implement.
 *
 * `Region` describes the properties of a memory region associated with a device.
 *
 * `MemoryMapper` is a utility class that manages the mapping of devices to regions of memory.
 * It provides methods to find a region by its address, get 8-bit or 16-bit unsigned integers from a specified address,
 * and set 8-bit or 16-bit unsigned integers at a specified address.
 *
 * @file
 * @see Device
 * @see Region
 * @see MemoryMapper
 */

/**
 * Interface for a device that can be mapped to memory.
 *
 * @export
 * @interface Device
 */
export interface Device {
  /**
   * Retrieves an 8-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @returns The 8-bit unsigned integer at the specified address.
   */
  getUint8: (address: number) => number

  /**
   * Retrieves a 16-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @returns The 16-bit unsigned integer at the specified address.
   */
  getUint16: (address: number) => number

  /**
   * Sets an 8-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @param value - The 8-bit unsigned integer to set.
   */
  setUint8: (address: number, value: number) => void

  /**
   * Sets a 16-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @param value - The 16-bit unsigned integer to set.
   */
  setUint16: (address: number, value: number) => void
}

/**
 * Interface for a region of memory associated with a device.
 *
 * @export
 * @interface Region
 */
export interface Region {
  device: Device // The associated device.
  start: number // The start address of the region.
  end: number // The end address of the region.
  remap: boolean // Whether the region should be remapped.
}

/**
 * Class to map devices to regions of memory.
 *
 * @export
 * @class MemoryMapper
 */
export class MemoryMapper {
  private regions: Array<Region>

  /**
   * Creates an instance of MemoryMapper.
   */
  constructor() {
    this.regions = []
  }

  /**
   * Maps a device to a region of memory.
   *
   * @param device - The device to map.
   * @param start - The start address of the region.
   * @param end - The end address of the region.
   * @param remap - Whether the region should be remapped. Default is true.
   *
   * @returns A function to unmap the region.
   */
  map(device: Device, start: number, size: number, remap = true) {
    const region: Region = {
      device,
      start,
      end: start + size - 1,
      remap,
    }

    this.regions.unshift(region)

    console.log(
      `Mapping from 0x${start.toString(16)} to 0x${(start + size - 1).toString(
        16
      )}`
    )

    return () => {
      this.regions = this.regions.filter((r) => r !== region)
    }
  }

  /**
   * Finds the region associated with a given address.
   *
   * @param address - The address to search for.
   * @throws If no region is found for the address.
   * @returns The region associated with the address.
   */
  findRegion(address: number): Region {
    const region = this.regions.find(
      (r) => address >= r.start && address <= r.end
    )
    if (!region) {
      throw new Error(`No region found for address ${address}`)
    }

    return region
  }

  /**
   * Retrieves a 16-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @returns The 16-bit unsigned integer at the specified address.
   */
  getUint16(address: number): number {
    const region = this.findRegion(address)
    const finalAddress = region.remap ? address - region.start : address
    try {
      return region.device.getUint16(finalAddress)
    } catch (ex) {
      console.error(
        `Attempted read from address 0x${address.toString(
          16
        )} of mapped device (final address=0x${finalAddress.toString(16)})`
      )
      console.log(this)
      // eslint-disable-next-line no-debugger
      debugger
      return 0
    }
  }

  /**
   * Retrieves an 8-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @returns The 8-bit unsigned integer at the specified address.
   */
  getUint8(address: number): number {
    const region = this.findRegion(address)
    const finalAddress = region.remap ? address - region.start : address
    try {
      return region.device.getUint8(finalAddress)
    } catch (ex) {
      console.error(
        `Attempted read from address 0x${address.toString(
          16
        )} of mapped device (final address=0x${finalAddress.toString(16)})`
      )
      console.log(this)
      // eslint-disable-next-line no-debugger
      debugger
      return 0
    }
  }

  /**
   * Sets a 16-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @param value - The 16-bit unsigned integer to set.
   */
  setUint16(address: number, value: number) {
    const region = this.findRegion(address)
    const finalAddress = region.remap ? address - region.start : address
    try {
      return region.device.setUint16(finalAddress, value)
    } catch (ex) {
      console.error(
        `Attempted write to address 0x${address.toString(
          16
        )} of mapped device (final address=0x${finalAddress.toString(16)})`
      )
      console.log(this)
      // eslint-disable-next-line no-debugger
      debugger
      return 0
    }
  }

  /**
   * Sets an 8-bit unsigned integer at the specified address.
   *
   * @param address - The memory address.
   * @param value - The 8-bit unsigned integer to set.
   */
  setUint8(address: number, value: number) {
    const region = this.findRegion(address)
    const finalAddress = region.remap ? address - region.start : address
    try {
      return region.device.setUint8(finalAddress, value)
    } catch (ex) {
      console.error(
        `Attempted write to address 0x${address.toString(
          16
        )} of mapped device (final address=0x${finalAddress.toString(16)})`
      )
      console.log(this)
      // eslint-disable-next-line no-debugger
      debugger
      return 0
    }
  }

  load(startAddress: number, data: number[]) {
    data.forEach((byte, offset) => this.setUint8(startAddress + offset, byte))
  }
}
