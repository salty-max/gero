/// Asm codegen — takes a parsed `ParseTree` and produces a
/// complete `.gx` byte image (header + image bytes). Single-file,
/// single-bank for the v0.1 first cut; banked emission lands later.
///
/// Two-pass model:
///   Pass 1 (layout): walk statements, compute each statement's
///     emit size via the opcode resolver, advance an emit cursor,
///     record label / data addresses in the SymbolTable.
///   Pass 2 (emit): walk statements again, emit opcode + operand
///     bytes against the populated table. Forward references are
///     resolvable now because pass 1 saw every label.
///
/// Org / forward gaps zero-pad between segments. Backward `org`
/// (target < current emit address) raises E014.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const ast = @import("ast.zig");
const expr = @import("expr.zig");
const include = @import("include.zig");
const parser_mod = @import("parser.zig");
const symtab = @import("symtab.zig");
const opres = @import("opcode_resolver.zig");

/// Output of the codegen pass — the complete `.gx` byte image
/// (header + body), the symbol table for debuggers + downstream
/// tools, and any diagnostics raised during layout / emit.
pub const Codegen = struct {
    /// The full `.gx` byte image, ready to write to disk.
    image: []u8,
    /// Populated symbol table.
    symbols: symtab.SymbolTable,
    /// Errors raised during codegen (E001..E016 per asm spec §8).
    errors: []include.Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the image buffer, symbol table, and error list.
    pub fn deinit(self: *Codegen) void {
        self.allocator.free(self.image);
        self.symbols.deinit();
        self.allocator.free(self.errors);
    }

    /// `true` when codegen surfaced at least one diagnostic.
    pub fn hasErrors(self: Codegen) bool {
        return self.errors.len > 0;
    }
};

/// Configuration knobs for `assemble`. v0.1 just exposes the
/// entry point; banking + SRAM land later.
pub const Options = struct {
    /// `ip` value at boot. Per ISA §7.1.
    entry_point: u16 = 0x0000,
};

/// Run the full codegen pipeline against a parsed program.
/// Never throws on grammar / semantic errors — those go into
/// `errors` (E001..E016 per spec §8). Only `Allocator.Error`
/// propagates.
pub fn assemble(
    allocator: std.mem.Allocator,
    source: []const u8,
    tree: parser_mod.ParseTree,
    opts: Options,
) !Codegen {
    var symbols = symtab.SymbolTable.init(allocator);
    errdefer symbols.deinit();
    var errors: std.ArrayList(include.Diagnostic) = .empty;
    errdefer errors.deinit(allocator);

    // Pass 1: layout. Walk statements, compute sizes, populate
    // symbol addresses. The emit cursor tracks where the next
    // byte will land.
    var image_size: u32 = 0;
    try layoutPass(&symbols, &errors, source, tree, &image_size);

    // Pass 2: emit. Project the populated symbol table down to a
    // ConstantTable so the expression evaluator can resolve every
    // symbol reference. Walk statements again, emit each byte.
    var image_buf: std.ArrayList(u8) = .empty;
    errdefer image_buf.deinit(allocator);

    var resolved_consts = try symbols.toConstantTable();
    defer resolved_consts.deinit();

    try emitPass(allocator, &image_buf, &errors, source, tree, resolved_consts, &symbols, image_size);

    // Prepend the .gx header per ISA §7.1.
    const image_bytes = try image_buf.toOwnedSlice(allocator);
    errdefer allocator.free(image_bytes);

    const final = try buildArchive(allocator, image_bytes, opts);
    allocator.free(image_bytes);

    return .{
        .image = final,
        .symbols = symbols,
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------- operand classification ----------

/// Classify an operand for layout / opcode selection, consulting
/// the in-progress symbol table for `label_ref` operands. During
/// layout, only forward-resolved consts can disambiguate;
/// unknown names default to `.addr` (same byte width as `.imm16`,
/// so sizing is correct either way).
fn classifyForLayout(op: ast.Operand, source: []const u8, symbols: symtab.SymbolTable) opres.Kind {
    return switch (op) {
        .label_ref => |l| opres.labelRefKind(source[l.span.start..l.span.end], symbols),
        else => opres.classify(op, null),
    };
}

/// Same as `classifyForLayout` but used in the emit pass. By
/// emit time, every label and const lives in the symbol table
/// with its true kind, so `label_ref` resolves precisely.
fn classifyForEmit(op: ast.Operand, source: []const u8, symbols: symtab.SymbolTable) opres.Kind {
    return switch (op) {
        .label_ref => |l| opres.labelRefKind(source[l.span.start..l.span.end], symbols),
        else => opres.classify(op, null),
    };
}

// ---------- pass 1: layout ----------

fn layoutPass(
    symbols: *symtab.SymbolTable,
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    tree: parser_mod.ParseTree,
    out_image_size: *u32,
) !void {
    var cursor: u32 = 0;
    for (tree.program.statements) |stmt| {
        switch (stmt) {
            .label => |l| {
                const name = source[l.name.start..l.name.end];
                // safety: cursor is bounded by max u16 image (the
                //         ISA caps at 64k) — cast won't truncate.
                const addr: u16 = @intCast(cursor);
                symbols.putBorrowed(name, .{ .kind = .label, .value = addr }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Duplicate => try errors.append(symbols.allocator, .{
                        .code = .duplicate_label,
                        .parse_error = core.parseError(
                            "codegen",
                            l.name.start,
                            "duplicate label",
                            .{ .expected = "unique label name", .actual = name, .kind = .semantic },
                        ),
                    }),
                };
            },
            .const_decl => |c| {
                // The parser already evaluated and stored this in
                // its internal ConstantTable, but that table got
                // dropped at end-of-parse. Re-eval here against
                // the symbol table we're building up.
                const name = source[c.name.start..c.name.end];
                var consts = try symbols.toConstantTable();
                defer consts.deinit();
                const result = expr.evalExpr(c.expr, source, consts);
                switch (result) {
                    .ok => |v| symbols.putBorrowed(name, .{ .kind = .const_value, .value = v }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // safety: const_value never triggers Duplicate per putBorrowed's rules
                        error.Duplicate => unreachable,
                    },
                    .err => |d| try errors.append(symbols.allocator, d),
                }
            },
            .data8, .data16 => |d| {
                const name = source[d.name.start..d.name.end];
                const addr: u16 = @intCast(cursor);
                symbols.putBorrowed(name, .{ .kind = .data, .value = addr }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Duplicate => try errors.append(symbols.allocator, .{
                        .code = .duplicate_label,
                        .parse_error = core.parseError(
                            "codegen",
                            d.name.start,
                            "duplicate data symbol",
                            .{ .expected = "unique data name", .actual = name, .kind = .semantic },
                        ),
                    }),
                };
                const word_size: u32 = if (stmt == .data8) 1 else 2;
                cursor += try sizeOfDataValues(d.values, word_size, source, symbols, errors);
            },
            .struct_decl => |sd| {
                const struct_name = source[sd.name.start..sd.name.end];
                for (sd.fields) |f| {
                    const field_name = source[f.name.start..f.name.end];
                    const qualified = try std.fmt.allocPrint(symbols.allocator, "{s}.{s}", .{ struct_name, field_name });
                    errdefer symbols.allocator.free(qualified);
                    try symbols.putOwned(qualified, .{ .kind = .struct_field, .value = f.offset });
                }
            },
            .org => |o| {
                if (o.addr) |target| {
                    if (target < cursor) {
                        try errors.append(symbols.allocator, .{
                            .code = .backward_org,
                            .parse_error = core.parseError(
                                "org",
                                o.span.start,
                                "backward `org` would overlap already-emitted bytes",
                                .{ .expected = "addr ≥ current emit position", .kind = .semantic },
                            ),
                        });
                    } else {
                        cursor = target;
                    }
                }
                // If `o.addr` is null the parser already emitted
                // a diagnostic. Leave the cursor alone.
            },
            .instruction => |i| {
                const mnem = source[i.mnemonic.start..i.mnemonic.end];
                var kinds: [3]opres.Kind = undefined;
                for (i.operands, 0..) |op, idx| kinds[idx] = classifyForLayout(op, source, symbols.*);
                if (opres.resolve(mnem, kinds[0..i.operands.len])) |res| {
                    cursor += res.size;
                } else {
                    // Unknown mnemonic OR operand-shape mismatch.
                    const known = opres.isKnownMnemonic(mnem);
                    const kind: []const u8 = if (known) "operand type mismatch" else "unknown mnemonic";
                    try errors.append(symbols.allocator, .{
                        .code = if (known) .operand_type_mismatch else .unknown_mnemonic,
                        .parse_error = core.parseError(
                            "codegen",
                            i.mnemonic.start,
                            kind,
                            .{ .expected = "valid instruction shape", .actual = mnem, .kind = .semantic },
                        ),
                    });
                    // Best-effort cursor advance to keep subsequent
                    // statements roughly aligned for layout.
                    cursor += 1;
                }
            },
            .unknown => {},
        }
    }
    out_image_size.* = cursor;
}

fn sizeOfDataValues(
    values: []const ast.DataValue,
    word_size: u32,
    source: []const u8,
    symbols: *symtab.SymbolTable,
    errors: *std.ArrayList(include.Diagnostic),
) !u32 {
    var total: u32 = 0;
    for (values) |v| switch (v) {
        .expr => total += word_size,
        .addr_lit => total += word_size,
        .sym_ref => total += word_size,
        .string => |s| {
            // The string token's lexeme is `"...escapes..."` so
            // we need to decode escapes to get the byte count.
            // (Identical logic to emit-time decoding; consolidate
            // into a shared helper if it grows.)
            const raw = source[s.span.start + 1 .. s.span.end - 1];
            total += @intCast(decodedStringLen(raw) * word_size);
        },
        .reserve => |r| {
            if (r.count) |n| {
                // @as: widen u16 → u32 for the byte-count math (can't overflow — u16 max × 2 = 131070, fits in u32)
                total += @as(u32, n) * word_size;
            } else {
                // Eval failed at parse time; re-try here against
                // the current symbol table.
                var consts = try symbols.toConstantTable();
                defer consts.deinit();
                const result = expr.evalExpr(r.count_expr, source, consts);
                switch (result) {
                    // @as: widen u16 → u32 for the byte-count math (can't overflow — u16 max × 2 = 131070, fits in u32)
                    .ok => |n| total += @as(u32, n) * word_size,
                    .err => |d| try errors.append(symbols.allocator, d),
                }
            }
        },
    };
    return total;
}

fn decodedStringLen(raw: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\' and i + 1 < raw.len) i += 1;
        n += 1;
    }
    return n;
}

// ---------- pass 2: emit ----------

fn emitPass(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    tree: parser_mod.ParseTree,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
    image_size: u32,
) !void {
    var cursor: u32 = 0;
    for (tree.program.statements) |stmt| {
        switch (stmt) {
            .label, .const_decl, .struct_decl, .unknown => {},
            .data8, .data16 => |d| {
                const word_size: u32 = if (stmt == .data8) 1 else 2;
                try emitDataValues(allocator, image, errors, source, d.values, word_size, consts);
                cursor = @intCast(image.items.len);
            },
            .org => |o| {
                if (o.addr) |target| {
                    if (target >= cursor) {
                        // Pad gap with zeros.
                        while (cursor < target) : (cursor += 1) {
                            try image.append(allocator, 0);
                        }
                    }
                    // Backward case already diagnosed in pass 1.
                }
            },
            .instruction => |i| {
                try emitInstruction(allocator, image, errors, source, i, consts, symbols);
                cursor = @intCast(image.items.len);
            },
        }
    }
    // Ensure the image is at least `image_size` bytes (pass 1's
    // layout target). Final pad if needed.
    while (image.items.len < image_size) try image.append(allocator, 0);
}

fn emitDataValues(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    values: []const ast.DataValue,
    word_size: u32,
    consts: expr.ConstantTable,
) !void {
    for (values) |v| switch (v) {
        .expr => |e| {
            const result = expr.evalExpr(e.expr, source, consts);
            switch (result) {
                .ok => |val| try emitValue(allocator, image, val, word_size),
                .err => |d| {
                    try errors.append(allocator, d);
                    try emitValue(allocator, image, 0, word_size); // zero placeholder
                },
            }
        },
        .addr_lit => |a| try emitValue(allocator, image, a.value, word_size),
        .sym_ref => |s| {
            const lex = source[s.span.start..s.span.end];
            const name = if (lex.len > 0 and lex[0] == '@') lex[1..] else lex;
            if (consts.get(name)) |val| {
                try emitValue(allocator, image, val, word_size);
            } else {
                try errors.append(allocator, .{
                    .code = .undefined_symbol,
                    .parse_error = core.parseError(
                        "codegen",
                        s.span.start,
                        "undefined symbol",
                        .{ .expected = "a defined label / const", .actual = name, .kind = .semantic },
                    ),
                });
                try emitValue(allocator, image, 0, word_size);
            }
        },
        .string => |s| {
            const raw = source[s.span.start + 1 .. s.span.end - 1];
            try emitString(allocator, image, raw, word_size);
        },
        .reserve => |r| {
            const n = if (r.count) |c| c else blk: {
                const result = expr.evalExpr(r.count_expr, source, consts);
                switch (result) {
                    .ok => |folded| break :blk folded,
                    .err => |d| {
                        try errors.append(allocator, d);
                        break :blk 0;
                    },
                }
            };
            var i: u32 = 0;
            // @as: widen u16 → u32 for the byte-count math (can't overflow — u16 max × 2 = 131070, fits in u32)
            const total = @as(u32, n) * word_size;
            while (i < total) : (i += 1) try image.append(allocator, 0);
        },
    };
}

fn emitValue(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    value: u16,
    width: u32,
) !void {
    if (width == 1) {
        try image.append(allocator, @intCast(value & 0xFF));
    } else {
        try image.append(allocator, @intCast(value & 0xFF));
        try image.append(allocator, @intCast((value >> 8) & 0xFF));
    }
}

fn emitString(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    raw: []const u8,
    word_size: u32,
) !void {
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var b: u8 = raw[i];
        if (b == '\\' and i + 1 < raw.len) {
            i += 1;
            b = switch (raw[i]) {
                '0' => 0x00,
                'n' => 0x0A,
                'r' => 0x0D,
                't' => 0x09,
                '\\' => 0x5C,
                '"' => 0x22,
                '\'' => 0x27,
                // safety: lexer validated escapes — anything else
                //         can't reach this branch.
                else => unreachable,
            };
        }
        try emitValue(allocator, image, b, word_size);
    }
}

fn emitInstruction(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    inst: ast.Instruction,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
) !void {
    const mnem = source[inst.mnemonic.start..inst.mnemonic.end];
    var kinds: [3]opres.Kind = undefined;
    for (inst.operands, 0..) |op, idx| kinds[idx] = classifyForEmit(op, source, symbols.*);
    const res = opres.resolve(mnem, kinds[0..inst.operands.len]) orelse {
        // Pass 1 already raised the diagnostic; emit a NOP-shape
        // 1 byte (0xFF / `hlt`) so the cursor advances by the
        // same amount we assumed for layout. Conservative but
        // keeps subsequent label addresses correct enough that
        // the rest of the diagnostics make sense.
        try image.append(allocator, 0xFF);
        return;
    };

    try image.append(allocator, res.opcode);

    for (inst.operands) |op| switch (op) {
        .register => |r| try image.append(allocator, @intFromEnum(r.id)),
        .immediate => |e| {
            const result = expr.evalExpr(e, source, consts);
            const val: u16 = switch (result) {
                .ok => |v| v,
                .err => |d| blk: {
                    try errors.append(allocator, d);
                    break :blk 0;
                },
            };
            try emitValue(allocator, image, val, 2);
        },
        .addr_lit => |a| try emitValue(allocator, image, a.value, 2),
        .sym_ref => |s| try emitSymRef(allocator, image, errors, source, s, consts),
        .label_ref => |l| try emitLabelRef(allocator, image, errors, source, l, consts),
        .addr_expr => |a| {
            const result = expr.evalExpr(a.expr, source, consts);
            const val: u16 = switch (result) {
                .ok => |v| v,
                .err => |d| blk: {
                    try errors.append(allocator, d);
                    break :blk 0;
                },
            };
            try emitValue(allocator, image, val, 2);
        },
        .cast => |c| try emitCast(allocator, image, errors, source, c, consts),
        .indirect => |ind| try image.append(allocator, @intFromEnum(ind.reg.id)),
        .indexed => |idx| {
            const result = expr.evalExpr(idx.addr, source, consts);
            const base: u16 = switch (result) {
                .ok => |v| v,
                .err => |d| blk: {
                    try errors.append(allocator, d);
                    break :blk 0;
                },
            };
            try emitValue(allocator, image, base, 2);
            try image.append(allocator, @intFromEnum(idx.reg.id));
        },
    };
}

fn emitSymRef(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    s: ast.SymRef,
    consts: expr.ConstantTable,
) !void {
    const lex = source[s.span.start..s.span.end];
    const name = if (lex.len > 0 and lex[0] == '@') lex[1..] else lex;
    if (consts.get(name)) |val| {
        try emitValue(allocator, image, val, 2);
    } else {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .parse_error = core.parseError(
                "codegen",
                s.span.start,
                "undefined symbol",
                .{ .expected = "defined label / const", .actual = name, .kind = .semantic },
            ),
        });
        try emitValue(allocator, image, 0, 2);
    }
}

fn emitLabelRef(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    l: ast.LabelRef,
    consts: expr.ConstantTable,
) !void {
    const name = source[l.span.start..l.span.end];
    if (consts.get(name)) |val| {
        try emitValue(allocator, image, val, 2);
    } else {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .parse_error = core.parseError(
                "codegen",
                l.span.start,
                "undefined symbol",
                .{ .expected = "defined label / const", .actual = name, .kind = .semantic },
            ),
        });
        try emitValue(allocator, image, 0, 2);
    }
}

fn emitCast(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    c: ast.CastOperand,
    consts: expr.ConstantTable,
) !void {
    // `<Type> @sym.field` desugars to `@sym + Type.field`.
    const sym_lex = source[c.sym_ref.span.start..c.sym_ref.span.end];
    const sym_name = if (sym_lex.len > 0 and sym_lex[0] == '@') sym_lex[1..] else sym_lex;
    const type_name = source[c.type_name.start..c.type_name.end];
    const field_name = source[c.field_name.start..c.field_name.end];

    const sym_val: u16 = if (consts.get(sym_name)) |v| v else blk: {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .parse_error = core.parseError(
                "codegen",
                c.sym_ref.span.start,
                "undefined symbol in cast",
                .{ .expected = "defined symbol", .actual = sym_name, .kind = .semantic },
            ),
        });
        break :blk 0;
    };

    // Look up `Type.field` as one key in the table.
    const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, field_name });
    defer allocator.free(qualified);
    const offset: u16 = if (consts.get(qualified)) |v| v else blk: {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .parse_error = core.parseError(
                "codegen",
                c.field_name.start,
                "unknown struct field",
                .{ .expected = "a declared `struct` field", .actual = field_name, .kind = .semantic },
            ),
        });
        break :blk 0;
    };

    try emitValue(allocator, image, sym_val +% offset, 2);
}

// ---------- header / archive ----------

/// Magic bytes at the start of a `.gx` file — "GERO" in ASCII.
const gx_magic = [4]u8{ 'G', 'E', 'R', 'O' };

fn buildArchive(allocator: std.mem.Allocator, image_bytes: []const u8, opts: Options) ![]u8 {
    // Header layout per ISA §7.1:
    //   0x00..0x04  magic = "GERO"
    //   0x04..0x06  u16le version = 0x0001
    //   0x06..0x08  u16le flags
    //   0x08..0x0A  u16le entry_point
    //   0x0A..0x0C  u16le image_size
    //   0x0C        u8 bank_count
    //   0x0D        u8 sram_bank_count
    //   0x0E..0x10  reserved (must be 0)
    const header_size: usize = 16;
    const total = header_size + image_bytes.len;
    var out = try allocator.alloc(u8, total);

    @memcpy(out[0..4], &gx_magic);
    writeU16Le(out[4..6], 0x0001); // version
    writeU16Le(out[6..8], 0x0000); // flags
    writeU16Le(out[8..10], opts.entry_point);
    // safety: image_size capped at 64 KiB by the ISA's 16-bit
    //         address space; cart code larger than that needs
    //         banking, which is a v0.1 follow-up.
    writeU16Le(out[10..12], @intCast(image_bytes.len));
    out[12] = 0; // bank_count
    out[13] = 0; // sram_bank_count
    writeU16Le(out[14..16], 0); // reserved

    @memcpy(out[header_size..], image_bytes);
    return out;
}

fn writeU16Le(dst: []u8, value: u16) void {
    // safety: caller passes a 2-byte slice — bounds-checked by indexing.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast((value >> 8) & 0xFF);
}
