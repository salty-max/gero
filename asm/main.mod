data16 myRectangle = { $A3, $1B, $04, $10 }
struct Rectangle {
    x: $02,
    y: $02,
    w: $02,
    h: $02,
}
start:
    mov8 &[ <Rectangle> myRectangle.y ], r1
    mov8 $03, r2
    add r1, r2
    jeq $05, &[!hello]
hello:
    mov &1234, r3
end:
    hlt