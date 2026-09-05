const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

test "symtab: empty table starts empty" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try std.testing.expect(st.get("nope") == null);
}

test "symtab: putBorrowed + get round-trips" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("start", .{ .kind = .label, .value = 0x1100 });
    const sym = st.get("start").?;
    try std.testing.expectEqual(gero.asm_.SymbolKind.label, sym.kind);
    try std.testing.expectEqual(@as(u16, 0x1100), sym.value);
}

test "symtab: duplicate label triggers error.Duplicate" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("foo", .{ .kind = .label, .value = 0x10 });
    try std.testing.expectError(
        error.Duplicate,
        st.putBorrowed("foo", .{ .kind = .label, .value = 0x20 }),
    );
}

test "symtab: duplicate data also triggers Duplicate" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("buf", .{ .kind = .data, .value = 0x10 });
    try std.testing.expectError(
        error.Duplicate,
        st.putBorrowed("buf", .{ .kind = .data, .value = 0x20 }),
    );
}

test "symtab: const_value silently overwrites" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("N", .{ .kind = .const_value, .value = 1 });
    try st.putBorrowed("N", .{ .kind = .const_value, .value = 2 });
    try std.testing.expectEqual(@as(u16, 2), st.get("N").?.value);
}

test "symtab: putOwned owns the key memory" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    const owned = try alloc.dupe(u8, "Player.hp");
    try st.putOwned(owned, .{ .kind = .struct_field, .value = 0 });
    try std.testing.expectEqual(@as(u16, 0), st.get("Player.hp").?.value);
    // Cleanup via st.deinit() frees the owned key — no leak.
}

test "symtab: suggestSimilar finds a close match for a typo" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("nowhere", .{ .kind = .label, .value = 0x10 });
    try st.putBorrowed("main", .{ .kind = .label, .value = 0x20 });
    // `nowher` (1 deletion) → "nowhere"
    try std.testing.expectEqualStrings("nowhere", st.suggestSimilar("nowher").?);
}

test "symtab: suggestSimilar returns null when nothing is close" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("foo", .{ .kind = .label, .value = 0 });
    try st.putBorrowed("bar", .{ .kind = .label, .value = 0 });
    try std.testing.expect(st.suggestSimilar("xyzqwertyu") == null);
}

test "symtab: toConstantTable projects to expr.ConstantTable" {
    var st = gero.asm_.SymbolTable.init(alloc);
    defer st.deinit();
    try st.putBorrowed("start", .{ .kind = .label, .value = 0x1100 });
    try st.putBorrowed("N", .{ .kind = .const_value, .value = 0x42 });

    var ct = try st.toConstantTable();
    defer ct.deinit();
    try std.testing.expectEqual(@as(u16, 0x1100), ct.get("start").?);
    try std.testing.expectEqual(@as(u16, 0x42), ct.get("N").?);
}

test "symtab: putOwned keeps the key on error.Duplicate" {
    var st = gero.asm_.SymbolTable.init(std.testing.allocator);
    defer st.deinit();
    const first = try std.testing.allocator.dupe(u8, "loop");
    try st.putOwned(first, .{ .kind = .label, .value = 0 });

    // A second label at the same name is a duplicate. Ownership never
    // transfers on that path, so this copy is still ours to free.
    const second = try std.testing.allocator.dupe(u8, "loop");
    try std.testing.expectError(error.Duplicate, st.putOwned(second, .{ .kind = .label, .value = 4 }));
    std.testing.allocator.free(second);
}

test "symtab: putOwned releases the key when registration fails" {
    // Walk the failure point across the allocations a registration
    // makes. Whichever one fails, the key must be freed exactly once —
    // the leak checker catches a miss, a double free traps.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const a = failing.allocator();
        var st = gero.asm_.SymbolTable.init(a);
        defer st.deinit();
        const name = a.dupe(u8, "Player.hp") catch continue;
        st.putOwned(name, .{ .kind = .struct_field, .value = 0 }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
    }
}
