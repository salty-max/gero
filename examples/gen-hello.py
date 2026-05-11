"""Generate examples/hello.gx — prints "Hello, gero!\n" then hlt."""
import struct
import sys

# Bytecode layout (entry = 0x0000):
#
#   0x0000  10 16 00 03    mov 0x0016, r2      ; r2 ← string addr
#   0x0004  24 03 02       mov8 [r2], r1       ; r1.lo ← mem[r2]
#   0x0007  60 02 00 00    cmp r1, 0           ; null-terminator check
#   0x000B  72 15 00       jeq 0x0015          ; if zero, jump to hlt
#   0x000E  FC 10          int 0x10            ; print r1.lo
#   0x0010  48 03          inc r2              ; r2++
#   0x0012  70 04 00       jmp 0x0004          ; loop
#   0x0015  FF             hlt
#   0x0016  "Hello, gero!\n\0"

code = bytes([
    0x10, 0x16, 0x00, 0x03,    # mov 0x0016, r2
    0x24, 0x03, 0x02,           # mov8 [r2], r1
    0x60, 0x02, 0x00, 0x00,    # cmp r1, 0
    0x72, 0x15, 0x00,           # jeq 0x0015
    0xFC, 0x10,                 # int 0x10
    0x48, 0x03,                 # inc r2
    0x70, 0x04, 0x00,           # jmp 0x0004
    0xFF,                        # hlt
])
string = b"Hello, gero!\n\0"
image = code + string

# Header: magic / version / flags / entry / image_size / bank_count / sram / reserved.
header = struct.pack('<4sHHHHBBH', b'GERO', 0x0001, 0, 0x0000, len(image), 0, 0, 0)
sys.stdout.buffer.write(header + image)
