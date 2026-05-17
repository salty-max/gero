const std = @import("std");
const gero = @import("gero");
const opcodes = gero.lang.codegen.internal.opcodes;

test "opcodes: Op.mov_imm16_reg matches the VM dispatch table entry" {
    try std.testing.expectEqual(@as(u8, 0x10), opcodes.Op.mov_imm16_reg);
}

test "opcodes: Reg.acu / Reg.fp / Reg.sp match the VM register file indices" {
    try std.testing.expectEqual(@as(u8, 0x01), opcodes.Reg.acu);
    try std.testing.expectEqual(@as(u8, 0x0A), opcodes.Reg.sp);
    try std.testing.expectEqual(@as(u8, 0x0B), opcodes.Reg.fp);
}

test "opcodes: Sys ids cover the host-callback syscall set" {
    try std.testing.expectEqual(@as(u8, 0x01), opcodes.Sys.print_str);
    try std.testing.expectEqual(@as(u8, 0x05), opcodes.Sys.print_fixed);
    try std.testing.expectEqual(@as(u8, 0x14), opcodes.Sys.format_terminate_buf);
}
