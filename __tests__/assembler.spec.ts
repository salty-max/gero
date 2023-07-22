import { assembleString, machineCodeAsHex } from '../src/assembler'

describe('instructions', () => {
  it('should parse MOV_LIT_REG correctly', () => {
    const input = 'mov $0042, r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x10 0x00 0x42 0x02')
  })

  it('should parse MOV_REG_REG correctly', () => {
    const input = 'mov r2, r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x11 0x03 0x02')
  })

  it('should parse MOV_REG_MEM correctly', () => {
    const input = 'mov r2, &0050'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x12 0x03 0x00 0x50')
  })

  it('should parse MOV_MEM_REG correctly', () => {
    const input = 'mov &0050, r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x13 0x00 0x50 0x02')
  })

  it('should parse MOV_LIT_MEM correctly', () => {
    const input = 'mov $0042, &0050'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x14 0x00 0x42 0x00 0x50')
  })

  it('should parse MOV_REG_PTR_REG correctly', () => {
    const input = 'mov &r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x15 0x02 0x03')
  })

  it('should parse MOV_LIT_OFF_REG correctly', () => {
    const input = 'mov $02, &r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x17 0x00 0x02 0x02 0x03')
  })

  it('should parse MOV8_LIT_MEM correctly', () => {
    const input = 'mov8 $02, &1234'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x70 0x02 0x12 0x34')
  })

  it('should parse MOV8_MEM_REG correctly', () => {
    const input = 'mov8 &1234, r1'
    const code = assembleString(input)
    console.log(machineCodeAsHex(code))

    expect(machineCodeAsHex(code)).toBe('0x71 0x12 0x34 0x02')
  })

  it('should parse MOVL_REG_MEM correctly', () => {
    const input = 'movl r1, &1234'
    const code = assembleString(input)
    console.log(machineCodeAsHex(code))

    expect(machineCodeAsHex(code)).toBe('0x72 0x02 0x12 0x34')
  })

  it('should parse MOVH_REG_MEM correctly', () => {
    const input = 'movh r1, &1234'
    const code = assembleString(input)
    console.log(machineCodeAsHex(code))

    expect(machineCodeAsHex(code)).toBe('0x73 0x02 0x12 0x34')
  })

  it('should parse MOV8_REG_PTR_REG correctly', () => {
    const input = 'mov8 &r1, r2'
    const code = assembleString(input)
    console.log(machineCodeAsHex(code))

    expect(machineCodeAsHex(code)).toBe('0x74 0x02 0x03')
  })

  it('should parse MOV8_REG_REG_PTR correctly', () => {
    const input = 'mov8 r1, &r2'
    const code = assembleString(input)
    console.log(machineCodeAsHex(code))

    expect(machineCodeAsHex(code)).toBe('0x75 0x02 0x03')
  })

  it('should parse ADD_LIT_REG correctly', () => {
    const input = 'add $02, r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x1B 0x00 0x02 0x02')
  })

  it('should parse ADD_REG_REG correctly', () => {
    const input = 'add r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x1C 0x02 0x03')
  })

  it('should parse sub_LIT_REG correctly', () => {
    const input = 'sub $02, r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x1D 0x00 0x02 0x02')
  })

  it('should parse sub_REG_LIT correctly', () => {
    const input = 'sub r1, $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x1E 0x02 0x00 0x02')
  })

  it('should parse sub_REG_REG correctly', () => {
    const input = 'sub r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x1F 0x02 0x03')
  })

  it('should parse MUL_LIT_REG correctly', () => {
    const input = 'mul $02, r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x20 0x00 0x02 0x02')
  })

  it('should parse MUL_REG_REG correctly', () => {
    const input = 'mul r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x21 0x02 0x03')
  })

  it('should parse INC_REG correctly', () => {
    const input = 'inc r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x35 0x02')
  })

  it('should parse DEC_REG correctly', () => {
    const input = 'dec r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x36 0x02')
  })

  it('should parse LSF_REG_LIT correctly', () => {
    const input = 'lsf r1, $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x26 0x02 0x00 0x02')
  })

  it('should parse LSF_REG_REG correctly', () => {
    const input = 'lsf r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x27 0x02 0x03')
  })

  it('should parse RSF_REG_LIT correctly', () => {
    const input = 'rsf r1, $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x2A 0x02 0x00 0x02')
  })

  it('should parse RSF_REG_REG correctly', () => {
    const input = 'rsf r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x2B 0x02 0x03')
  })

  it('should parse AND_REG_LIT correctly', () => {
    const input = 'and r1, $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x2E 0x02 0x00 0x02')
  })

  it('should parse AND_REG_REG correctly', () => {
    const input = 'and r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x2F 0x02 0x03')
  })

  it('should parse OR_REG_LIT correctly', () => {
    const input = 'or r1, $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x30 0x02 0x00 0x02')
  })

  it('should parse OR_REG_REG correctly', () => {
    const input = 'or r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x31 0x02 0x03')
  })

  it('should parse XOR_REG_LIT correctly', () => {
    const input = 'xor r1, $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x32 0x02 0x00 0x02')
  })

  it('should parse XOR_REG_REG correctly', () => {
    const input = 'xor r1, r2'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x33 0x02 0x03')
  })

  it('should parse NOT correctly', () => {
    const input = 'not r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x34 0x02')
  })

  it('should parse JEQ_REG correctly', () => {
    const input = 'jeq r1, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x3E 0x02 0x00 0x60')
  })

  it('should parse JEQ_LIT correctly', () => {
    const input = 'jeq $02, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x3F 0x00 0x02 0x00 0x60')
  })

  it('should parse JNE_REG correctly', () => {
    const input = 'jne r1, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x40 0x02 0x00 0x60')
  })

  it('should parse JNE_LIT correctly', () => {
    const input = 'jne $02, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x41 0x00 0x02 0x00 0x60')
  })

  it('should parse JLT_REG correctly', () => {
    const input = 'jlt r1, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x42 0x02 0x00 0x60')
  })

  it('should parse JLT_LIT correctly', () => {
    const input = 'jlt $02, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x43 0x00 0x02 0x00 0x60')
  })

  it('should parse JGT_REG correctly', () => {
    const input = 'jgt r1, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x44 0x02 0x00 0x60')
  })

  it('should parse JGT_LIT correctly', () => {
    const input = 'jgt $02, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x45 0x00 0x02 0x00 0x60')
  })

  it('should parse JLE_REG correctly', () => {
    const input = 'jle r1, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x46 0x02 0x00 0x60')
  })

  it('should parse JLE_LIT correctly', () => {
    const input = 'jle $02, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x47 0x00 0x02 0x00 0x60')
  })

  it('should parse JGE_REG correctly', () => {
    const input = 'jge r1, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x48 0x02 0x00 0x60')
  })

  it('should parse JGE_LIT correctly', () => {
    const input = 'jge $02, &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x49 0x00 0x02 0x00 0x60')
  })

  it('should parse PSH_LIT correctly', () => {
    const input = 'psh $02'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x18 0x00 0x02')
  })

  it('should parse PSH_REG correctly', () => {
    const input = 'psh r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x19 0x02')
  })

  it('should parse POP correctly', () => {
    const input = 'pop acu'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x1A 0x01')
  })

  it('should parse CAL_LIT correctly', () => {
    const input = 'cal &0060'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x5E 0x00 0x60')
  })

  it('should parse CAL_REG correctly', () => {
    const input = 'cal r1'
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x5F 0x02')
  })
})

describe('labels', () => {
  it('should ignore labels during parsing', () => {
    const input = [`start:`, ` mov $42, r1`].join('\n')
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x10 0x00 0x42 0x02')
  })

  it('should handle labels as adresses', () => {
    const input = [`mov $42, r1`, `jump:`, ` jeq r1, &[!jump]`].join('\n')
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe(
      '0x10 0x00 0x42 0x02 0x3E 0x02 0x00 0x04'
    )
  })
})

describe('constants', () => {
  it('should ignore contants during parsing', () => {
    const input = [`constant code = $C0DE`, ` mov $42, r1`].join('\n')
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x10 0x00 0x42 0x02')
  })

  it('should handle constants as literals', () => {
    const input = [
      `constant code = $C0DE`,
      `mov [!code], r1`,
      `jump:`,
      ` jeq r1, &[!jump]`,
    ].join('\n')
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe(
      '0x10 0xC0 0xDE 0x02 0x3E 0x02 0x00 0x04'
    )
  })
})

describe('data', () => {
  it('should handle data8 values as literals', () => {
    const input = [`data8 bytes = { $01, $02, $03, $04 }`].join('\n')
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe('0x01 0x02 0x03 0x04')
  })

  it('should handle data16 values as literals', () => {
    const input = [`data16 words = { $0102, $0304, $0506, $0708 }`].join('\n')
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe(
      '0x01 0x02 0x03 0x04 0x05 0x06 0x07 0x08'
    )
  })
})

describe('structs', () => {
  it('should handle correctly fetch value from struct property', () => {
    const input = [
      'data16 myRectangle = { $A3, $1B, $04, $10 }',
      'struct Rectangle {',
      '  x: $2,',
      '  y: $2,',
      '  w: $2,',
      '  h: $2,',
      '}',
      'start:',
      ' mov &[ <Rectangle> myRectangle.y ], r1',
    ]
      .join('\n')
      .trim()
    const code = assembleString(input)

    expect(machineCodeAsHex(code)).toBe(
      '0x00 0xA3 0x00 0x1B 0x00 0x04 0x00 0x10 0x13 0x00 0x02 0x02'
    )
  })
})

describe('program', () => {
  it('should correctly parse an entire program', () => {
    const exampleProgram = [
      'start:',
      ' mov $0A, &0050',
      'loop:',
      ' mov &0050, acu',
      ' dec acu',
      ' mov acu, &0050',
      ' inc r2',
      ' inc r2',
      ' inc r2',
      ' jne $00, &[!loop]',
      'end:',
      ' hlt',
    ].join('\n')
    const code = assembleString(exampleProgram)

    expect(machineCodeAsHex(code)).toBe(
      '0x14 0x00 0x0A 0x00 0x50 0x13 0x00 0x50 0x01 0x36 0x01 0x12 0x01 0x00 0x50 0x35 0x03 0x35 0x03 0x35 0x03 0x41 0x00 0x00 0x00 0x05 0xFF'
    )
  })
})
