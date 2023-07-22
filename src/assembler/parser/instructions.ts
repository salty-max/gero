import P from 'parsil'

import {
  litMem,
  litOffReg,
  litReg,
  memReg,
  noArgs,
  regLit,
  regMem,
  regPtrReg,
  regRegPtr,
  regReg,
  singleAddr,
  singleLit,
  singleReg,
} from './formats'

export const mov = P.choice([
  litOffReg('mov', 'MOV_LIT_OFF_REG'),
  regReg('mov', 'MOV_REG_REG'),
  litReg('mov', 'MOV_LIT_REG'),
  memReg('mov', 'MOV_MEM_REG'),
  regMem('mov', 'MOV_REG_MEM'),
  regMem('mov', 'MOVL_REG_MEM'),
  regMem('mov', 'MOVH_REG_MEM'),
  litMem('mov', 'MOV_LIT_MEM'),
  regPtrReg('mov', 'MOV_REG_PTR_REG'),
])

export const mov8 = P.choice([
  memReg('mov8', 'MOV8_MEM_REG'),
  litMem('mov8', 'MOV8_LIT_MEM'),
  regPtrReg('mov8', 'MOV8_REG_PTR_REG'),
  regRegPtr('mov8', 'MOV8_REG_REG_PTR'),
])

export const movl = regMem('movl', 'MOVL_REG_MEM')

export const movh = regMem('movh', 'MOVH_REG_MEM')

export const add = P.choice([
  regReg('add', 'ADD_REG_REG'),
  litReg('add', 'ADD_LIT_REG'),
])

export const sub = P.choice([
  regReg('sub', 'SUB_REG_REG'),
  litReg('sub', 'SUB_LIT_REG'),
  regLit('sub', 'SUB_REG_LIT'),
])

export const mul = P.choice([
  regReg('mul', 'MUL_REG_REG'),
  litReg('mul', 'MUL_LIT_REG'),
])

export const lsf = P.choice([
  regReg('lsf', 'LSF_REG_REG'),
  regLit('lsf', 'LSF_REG_LIT'),
])

export const rsf = P.choice([
  regReg('rsf', 'RSF_REG_REG'),
  regLit('rsf', 'RSF_REG_LIT'),
])

export const and = P.choice([
  regReg('and', 'AND_REG_REG'),
  regLit('and', 'AND_REG_LIT'),
])

export const or = P.choice([
  regReg('or', 'OR_REG_REG'),
  regLit('or', 'OR_REG_LIT'),
])

export const xor = P.choice([
  regReg('xor', 'XOR_REG_REG'),
  regLit('xor', 'XOR_REG_LIT'),
])

export const inc = singleReg('inc', 'INC_REG')
export const dec = singleReg('dec', 'DEC_REG')
export const not = singleReg('not', 'NOT')

export const jeq = P.choice([
  regMem('jeq', 'JEQ_REG'),
  litMem('jeq', 'JEQ_LIT'),
])

export const jne = P.choice([
  regMem('jne', 'JNE_REG'),
  litMem('jne', 'JNE_LIT'),
])

export const jlt = P.choice([
  regMem('jlt', 'JLT_REG'),
  litMem('jlt', 'JLT_LIT'),
])

export const jgt = P.choice([
  regMem('jgt', 'JGT_REG'),
  litMem('jgt', 'JGT_LIT'),
])

export const jle = P.choice([
  regMem('jle', 'JLE_REG'),
  litMem('jle', 'JLE_LIT'),
])

export const jge = P.choice([
  regMem('jge', 'JGE_REG'),
  litMem('jge', 'JGE_LIT'),
])

export const psh = P.choice([
  singleLit('psh', 'PSH_LIT'),
  singleReg('psh', 'PSH_REG'),
])

export const pop = singleReg('pop', 'POP')

export const cal = P.choice([
  singleAddr('cal', 'CAL_LIT'),
  singleReg('cal', 'CAL_REG'),
])

export const ret = noArgs('ret', 'RET')
export const hlt = noArgs('hlt', 'HLT')

export default P.choice([
  mov,
  mov8,
  movl,
  movh,
  add,
  sub,
  mul,
  inc,
  dec,
  lsf,
  rsf,
  and,
  or,
  xor,
  not,
  jeq,
  jne,
  jlt,
  jgt,
  jle,
  jge,
  psh,
  pop,
  cal,
  ret,
  hlt,
])
