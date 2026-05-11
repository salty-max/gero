const std = @import("std");
const gero = @import("gero");

test "asm.assembleHlt: 'hlt' → single 0xFF byte" {
    const bytes = try gero.asm_.assembleHlt(std.testing.allocator, "hlt");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xFF}, bytes);
}

test "asm.assembleHlt: whitespace around the mnemonic is fine" {
    const bytes = try gero.asm_.assembleHlt(std.testing.allocator, "  hlt\n");
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xFF}, bytes);
}

test "asm.assembleHlt: unknown mnemonic returns ParseFailed" {
    try std.testing.expectError(
        error.ParseFailed,
        gero.asm_.assembleHlt(std.testing.allocator, "nop"),
    );
}

test "asm.assembleHlt: trailing garbage after hlt rejects" {
    try std.testing.expectError(
        error.ParseFailed,
        gero.asm_.assembleHlt(std.testing.allocator, "hlt extra"),
    );
}

test "asm → vm integration: assembled hlt runs and halts" {
    const allocator = std.testing.allocator;
    const image = try gero.asm_.assembleHlt(allocator, "hlt");
    defer allocator.free(image);

    var vm = gero.vm.VM.init(allocator);
    defer vm.deinit();
    // Drop the assembled byte at the entry point and run.
    vm.regs.write(.ip, 0x1100);
    vm.mmap.writeByte(0x1100, image[0]);
    try std.testing.expectEqual(gero.vm.StepResult.halted, gero.vm.run(&vm));
}
