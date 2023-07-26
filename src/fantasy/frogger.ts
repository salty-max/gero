const hex = (n: number) => n.toString(16).padStart(4, '0')
const addr = (n: number) => `&${hex(n)}`
const lit = (n: number) => `$${hex(n)}`
const negative = (n: number) => lit((~n & 0xffff) + 1)
const structOffset = (struct: string, property: string) =>
  `[<${struct}> ${addr(0)}.${property}]`

/* prettier-ignore */
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export default ({ cars }: { cars: number }) =>
  `

struct Sprite {
  x: $02, y: $02,
  tileIndex: $01, animationOffset: $01
}

struct Frog {
  x: $02, y: $02,
  tileIndex: $01
}

struct Car {
  x: $02, y: $02,
  tileIndex: $01, animationOffset: $01,
  ignore0: $03,
  velocity: $02
}

struct Input {
  Up: $01, Down: $01,
  Left: $01, Right: $01,
  A: $01, B: $01,
  Start: $01, Select: $01
}

struct Box {
  x: $02, y: $02,
  x2: $02, y2: $02
}

constant InputAddr = $2620
constant FrogAddr = $2020
constant SpriteMemory = $2020
constant FrogBox = $5000
constant OtherBox = $5008

start:

check_up_pressed:
  mov8 &[<Input> InputAddr.Up], acu
  jeq ${lit(0)}, &[!check_down_pressed]
  mov &[<Frog> FrogAddr.y], r1
  add ${negative(4)}, r1
  mov acu, &[<Frog> FrogAddr.y]

check_down_pressed:
  mov8 &[<Input> InputAddr.Down], acu
  jeq ${lit(0)}, &[!check_left_pressed]
  mov &[<Frog> FrogAddr.y], r1
  add ${lit(4)}, r1
  mov acu, &[<Frog> FrogAddr.y]

check_left_pressed:
  mov8 &[<Input> InputAddr.Left], acu
  jeq ${lit(0)}, &[!check_right_pressed]
  mov &[<Frog> FrogAddr.x], r1
  add ${negative(4)}, r1
  mov acu, &[<Frog> FrogAddr.x]

check_right_pressed:
  mov8 &[<Input> InputAddr.Right], acu
  jeq ${lit(0)}, &[!check_input_end]
  mov &[<Frog> FrogAddr.x], r1
  add ${lit(4)}, r1
  mov acu, &[<Frog> FrogAddr.x]

check_input_end:

update_cars:

  mov8 &[!carsOffset], acu                  ;; load cars offset into the acu
  jeq ${lit(
    0x20
  )}, &[!end_of_update_cars]  ;; jump if we've processed all the cars

  ;; write the next car offset into memory
  mov acu, r5
  add ${lit(0x10)}, acu
  movl acu, &[!carsOffset]
  mov r5, acu

  add $2030, acu ;; place address of the current car into the acu
  mov acu, r5           ;; place car address into r5
  mov &acu, r1          ;; load the xpos into r1

  ;; calculate the address of the speed property of the car and place in the acu
  add ${structOffset('Car', 'velocity')}, r5

  mov &acu, acu         ;; put the value of the speed property in the acu
  add acu, r1           ;; calculate the new x position, place in acu
  mov acu, &r5          ;; move the new x value to the cars x property

  ;; Negative bounds detection
  mov acu, r6
  and acu, $8000
  jeq $0000, &[!positive_bounds_check]
  mov ${lit(240)}, &r5
  mov [!end_of_bounds_check], ip

positive_bounds_check:
  mov r6, acu
  jgt ${lit(240)}, &[!end_of_bounds_check]
  ;;mov ${lit(0)}, &r5

end_of_bounds_check:
  mov [!update_cars], ip  ;; Jump back to the top of the loop

end_of_update_cars:
  mov ${lit(0)}, &[!carsOffset]

end_of_game_logic:
  mov8 ${lit(1)}, &[!hasEnded]
end_of_game_logic_loop:
  mov [!end_of_game_logic_loop], ip

after_frame:
  psh acu
  mov8 &[!hasEnded], acu
  jeq ${lit(0)}, &[!after_frame_2]
  mov8 ${lit(0)}, &[!hasEnded]
  pop acu
  pop r8
  psh [!start]
  rti

after_frame_2:
  pop acu
  rti

data8 hasEnded = { ${lit(0)} }
data8 carsOffset = { ${lit(0)} }
`.trim()
