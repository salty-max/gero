// const hex = (n: number) => n.toString(16).padStart(4, '0')
// const addr = (n: number) => `&${hex(n)}`
// const lit = (n: number) => `$${hex(n)}`
// const negative = (n: number) => lit((~n & 0xffff) + 1)

/* prettier-ignore */
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export default ({ frog, input }: { frog: number; input: number }) =>
  `
constant frog = $2020
constant input = $2620

start:

check_up_pressed:
  mov8 &[!input], acu
  jeq $00, &[!check_down_pressed]
  mov &[!frog + $02], r1
  add $04, r1
  mov acu, &[!frog + $02]

check_down_pressed:
  mov8 &[!input + $01], acu
  jeq $00, &[!check_left_pressed]
  mov &[!frog + $02], r1
  add $04, r1
  mov acu, &[!frog + $02]
check_left_pressed:
check_right_pressed:


end_of_game_logic:
  mov8 $01, &[!hasEnded]
end_of_game_logic_loop:
  mov [!end_of_game_logic_loop], ip

after_frame:
  psh acu
  mov8 &[!hasEnded], acu
  jeq $00, &[!after_frame_2]
  mov8 $00, &[!hasEnded]
  pop acu
  pop r8
  psh [!start]
  rti

after_frame_2:
  pop acu
  rti

data8 hasEnded = { $00 }
`.trim()
