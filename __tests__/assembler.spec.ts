import { parseProgram, machineCode16 } from '../src/assembler'

describe('instructions', () => {
  it('should parse MOV_LIT_REG correctly', () => {
    const input = 'mov $0042, r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('10 00 42 02')
  })

  it('should parse MOV_REG_REG correctly', () => {
    const input = 'mov r2, r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('11 03 02')
  })

  it('should parse MOV_REG_MEM correctly', () => {
    const input = 'mov r2, &0050'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('12 03 00 50')
  })

  it('should parse MOV_MEM_REG correctly', () => {
    const input = 'mov &0050, r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('13 00 50 02')
  })

  it('should parse MOV_LIT_MEM correctly', () => {
    const input = 'mov $0042, &0050'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('14 00 42 00 50')
  })

  it('should parse MOV_REG_PTR_REG correctly', () => {
    const input = 'mov &r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('15 02 03')
  })

  it('should parse MOV_LIT_OFF_REG correctly', () => {
    const input = 'mov $02, &r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('16 00 02 02 03')
  })

  it('should parse ADD_LIT_REG correctly', () => {
    const input = 'add $02, r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('1B 00 02 02')
  })

  it('should parse ADD_REG_REG correctly', () => {
    const input = 'add r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('1C 02 03')
  })

  it('should parse sub_LIT_REG correctly', () => {
    const input = 'sub $02, r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('1D 00 02 02')
  })

  it('should parse sub_REG_LIT correctly', () => {
    const input = 'sub r1, $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('1E 02 00 02')
  })

  it('should parse sub_REG_REG correctly', () => {
    const input = 'sub r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('1F 02 03')
  })

  it('should parse MUL_LIT_REG correctly', () => {
    const input = 'mul $02, r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('20 00 02 02')
  })

  it('should parse MUL_REG_REG correctly', () => {
    const input = 'mul r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('21 02 03')
  })

  it('should parse INC_REG correctly', () => {
    const input = 'inc r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('35 02')
  })

  it('should parse DEC_REG correctly', () => {
    const input = 'dec r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('36 02')
  })

  it('should parse LSF_REG_LIT correctly', () => {
    const input = 'lsf r1, $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('26 02 00 02')
  })

  it('should parse LSF_REG_REG correctly', () => {
    const input = 'lsf r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('27 02 03')
  })

  it('should parse RSF_REG_LIT correctly', () => {
    const input = 'rsf r1, $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('2A 02 00 02')
  })

  it('should parse RSF_REG_REG correctly', () => {
    const input = 'rsf r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('2B 02 03')
  })

  it('should parse AND_REG_LIT correctly', () => {
    const input = 'and r1, $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('2E 02 00 02')
  })

  it('should parse AND_REG_REG correctly', () => {
    const input = 'and r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('2F 02 03')
  })

  it('should parse OR_REG_LIT correctly', () => {
    const input = 'or r1, $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('30 02 00 02')
  })

  it('should parse OR_REG_REG correctly', () => {
    const input = 'or r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('31 02 03')
  })

  it('should parse XOR_REG_LIT correctly', () => {
    const input = 'xor r1, $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('32 02 00 02')
  })

  it('should parse XOR_REG_REG correctly', () => {
    const input = 'xor r1, r2'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('33 02 03')
  })

  it('should parse NOT correctly', () => {
    const input = 'not r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('34 02')
  })

  it('should parse JEQ_REG correctly', () => {
    const input = 'jeq r1, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('3E 02 00 60')
  })

  it('should parse JEQ_LIT correctly', () => {
    const input = 'jeq $02, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('3F 00 02 00 60')
  })

  it('should parse JNE_REG correctly', () => {
    const input = 'jne r1, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('40 02 00 60')
  })

  it('should parse JNE_LIT correctly', () => {
    const input = 'jne $02, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('41 00 02 00 60')
  })

  it('should parse JLT_REG correctly', () => {
    const input = 'jlt r1, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('42 02 00 60')
  })

  it('should parse JLT_LIT correctly', () => {
    const input = 'jlt $02, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('43 00 02 00 60')
  })

  it('should parse JGT_REG correctly', () => {
    const input = 'jgt r1, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('44 02 00 60')
  })

  it('should parse JGT_LIT correctly', () => {
    const input = 'jgt $02, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('45 00 02 00 60')
  })

  it('should parse JLE_REG correctly', () => {
    const input = 'jle r1, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('46 02 00 60')
  })

  it('should parse JLE_LIT correctly', () => {
    const input = 'jle $02, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('47 00 02 00 60')
  })

  it('should parse JGE_REG correctly', () => {
    const input = 'jge r1, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('48 02 00 60')
  })

  it('should parse JGE_LIT correctly', () => {
    const input = 'jge $02, &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('49 00 02 00 60')
  })

  it('should parse PSH_LIT correctly', () => {
    const input = 'psh $02'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('17 00 02')
  })

  it('should parse PSH_REG correctly', () => {
    const input = 'psh r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('18 02')
  })

  it('should parse POP correctly', () => {
    const input = 'pop acc'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('1A 01')
  })

  it('should parse CAL_LIT correctly', () => {
    const input = 'cal &0060'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('5E 00 60')
  })

  it('should parse CAL_REG correctly', () => {
    const input = 'cal r1'
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('5F 02')
  })
})

describe('labels', () => {
  it('should ignore labels during parsing', () => {
    const input = [`start:`, ` mov $42, r1`].join('\n')
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('10 00 42 02')
  })

  it('should handle labels as adresses', () => {
    const input = [`mov $42, r1`, `jump:`, ` jeq r1, &[!jump]`].join('\n')
    const code = parseProgram(input)

    expect(machineCode16(code)).toBe('10 00 42 02 3E 02 00 04')
  })
})

describe('program', () => {
  it('should correctly parse an entire program', () => {
    const exampleProgram = [
      'start:',
      ' mov $0A, &0050',
      'loop:',
      ' mov &0050, acc',
      ' dec acc',
      ' mov acc, &0050',
      ' inc r2',
      ' inc r2',
      ' inc r2',
      ' jne $00, &[!loop]',
      'end:',
      ' hlt',
    ].join('\n')
    const code = parseProgram(exampleProgram)

    expect(machineCode16(code)).toBe(
      '14 00 0A 00 50 13 00 50 01 36 01 12 01 00 50 35 03 35 03 35 03 41 00 00 00 05 FF'
    )
  })
})
