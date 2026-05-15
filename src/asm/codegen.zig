/// Asm codegen — takes a parsed `ParseTree` and produces a
/// complete `.gx` byte image (header + image bytes). Banked
/// emission is supported via the `bank N` directive.
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
    /// Errors raised during codegen (E001..E016 per asm spec §7).
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

/// Configuration knobs for `assemble`.
pub const Options = struct {
    /// `ip` value at boot per ISA §7.1. `null` (default) triggers
    /// auto-detection: if the program defines a `main:` label, its
    /// address is used; otherwise the entry point is `0x0000`
    /// (start of image). Set explicitly to override.
    entry_point: ?u16 = null,
    /// When `true` (default) emit the debug-symbol section per
    /// ISA §7.3 — every global `label:` and `data8/16` declaration
    /// becomes a `(address, name)` entry. Disable for "release"
    /// builds that want to strip the names.
    debug_symbols: bool = true,
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
    // symbol addresses. Tracks one cursor per bank (base + 1..N)
    // and the highest bank index seen so the header gets it right.
    var layout: Layout = .{
        .base_size = 0,
        .bank_sizes = std.AutoHashMap(u8, u32).init(allocator),
        .max_bank = null,
        .sram_banks = 0,
        .sram_banks_span = null,
    };
    defer layout.bank_sizes.deinit();
    try layoutPass(&symbols, &errors, source, tree, &layout);
    try validateSramBanks(&errors, &layout, allocator);

    // Pass 2: emit. Per-bank buffers; the same `current_bank` state
    // walks alongside the layout state.
    var emit: Emit = .{
        .base = .empty,
        .banks = std.AutoHashMap(u8, std.ArrayList(u8)).init(allocator),
    };
    defer {
        emit.base.deinit(allocator);
        var it = emit.banks.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        emit.banks.deinit();
    }

    var resolved_consts = try symbols.toConstantTable();
    defer resolved_consts.deinit();

    try emitPass(allocator, &emit, &errors, source, tree, resolved_consts, &symbols, &layout);

    // Resolve the entry point: explicit option wins; otherwise
    // prefer a `main:` label, else default to `0x0000`.
    const resolved_entry: u16 = opts.entry_point orelse blk: {
        if (symbols.get("main")) |sym| {
            if (sym.kind == .label) break :blk sym.value;
        }
        break :blk 0x0000;
    };

    const final = try buildArchive(allocator, &emit, &layout, resolved_entry, &symbols, opts.debug_symbols);

    return .{
        .image = final,
        .symbols = symbols,
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------- bank state ----------

/// Per-bank tracking shared by layout + emit. `base_size` is the
/// final size of the base image (the implicit no-bank-declared
/// region); `bank_sizes[N]` is the final size of bank slot N
/// (0-based, accessed at runtime by `mb = N`). `max_bank == null`
/// means no `bank N` directive was seen; otherwise it's the
/// highest 0-based slot index declared. `sram_banks` is the
/// latest `sram_banks N` value; `sram_banks_span` is the source
/// span of the directive that set it (carried so the post-layout
/// validator can caret-point at the offending line).
const Layout = struct {
    base_size: u32,
    bank_sizes: std.AutoHashMap(u8, u32),
    max_bank: ?u8,
    sram_banks: u8,
    sram_banks_span: ?ast.Span,
};

/// Per-bank emit buffers. Base image lives outside the banks
/// hashmap; banks 0..max_bank live inside it. Each bank holds
/// 15.75 KB usable per ISA §5 (padded to 16 KB on disk).
const Emit = struct {
    base: std.ArrayList(u8),
    banks: std.AutoHashMap(u8, std.ArrayList(u8)),
};

/// Bank window base address per ISA §5 — banked content is
/// addressed in CPU space at `0xC000 + offset_in_bank`.
const bank_window_base: u16 = 0xC000;

/// 16 KB per bank on disk, per ISA §7.1.
const bank_disk_size: u32 = 0x4000;

/// Return the CPU address corresponding to `offset` within
/// `bank` — base image stays at `offset` (low RAM), banks shift
/// into the 0xC000 window.
fn bankAddr(bank: ?u8, offset: u32) u16 {
    // safety: base image bounded at 64 KiB; bank offsets at
    //         15.75 KiB — the u16 cast never truncates.
    if (bank == null) return @intCast(offset);
    // @as: same bound — bank offset fits u16 (window is 15.75 KiB).
    return bank_window_base +% @as(u16, @intCast(offset));
}

/// Get the layout cursor for the current `bank`. Auto-initialized
/// to 0 the first time a bank is touched.
fn layoutCursor(layout: *Layout, bank: ?u8) !*u32 {
    if (bank) |b| {
        const entry = try layout.bank_sizes.getOrPut(b);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        return entry.value_ptr;
    }
    return &layout.base_size;
}

/// Get (or create) the emit buffer for the current `bank`.
fn emitBuffer(allocator: std.mem.Allocator, emit: *Emit, bank: ?u8) !*std.ArrayList(u8) {
    _ = allocator; // present for symmetry — list ops take allocator on use
    if (bank) |b| {
        const entry = try emit.banks.getOrPut(b);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        return entry.value_ptr;
    }
    return &emit.base;
}

/// True for the two cross-bank pseudo-instructions. Both desugar
/// to `mov $bank, mb` + `call`/`jmp <addr>` — 7 bytes total. The
/// caller is responsible for the actual emit; this helper just
/// gates the special-case path in layout + emit.
fn isBankPseudo(mnem: []const u8) bool {
    return std.mem.eql(u8, mnem, "bank_call") or std.mem.eql(u8, mnem, "bank_jump");
}

// ---------- operand classification ----------

/// Classify an operand for layout / opcode selection, consulting
/// the in-progress symbol table for `label_ref` operands. During
/// layout, only forward-resolved consts can disambiguate;
/// unknown names default to `.addr` (same byte width as `.imm16`,
/// so sizing is correct either way).
fn classifyForLayout(
    op: ast.Operand,
    source: []const u8,
    symbols: symtab.SymbolTable,
    parent_label: ?[]const u8,
    scratch: std.mem.Allocator,
) opres.Kind {
    return switch (op) {
        .label_ref => |l| blk: {
            const lex = source[l.span.start..l.span.end];
            const resolved = resolveLabelKey(lex, parent_label, scratch) catch break :blk .addr;
            defer if (resolved.owned) scratch.free(resolved.key);
            break :blk opres.labelRefKind(resolved.key, symbols);
        },
        .immediate => |e| narrowImm(e, source, symbols),
        else => opres.classify(op, null),
    };
}

/// Same as `classifyForLayout` but used in the emit pass. By
/// emit time, every label and const lives in the symbol table
/// with its true kind, so `label_ref` resolves precisely.
fn classifyForEmit(
    op: ast.Operand,
    source: []const u8,
    symbols: symtab.SymbolTable,
    parent_label: ?[]const u8,
    scratch: std.mem.Allocator,
) opres.Kind {
    return switch (op) {
        .label_ref => |l| blk: {
            const lex = source[l.span.start..l.span.end];
            const resolved = resolveLabelKey(lex, parent_label, scratch) catch break :blk .addr;
            defer if (resolved.owned) scratch.free(resolved.key);
            break :blk opres.labelRefKind(resolved.key, symbols);
        },
        .immediate => |e| narrowImm(e, source, symbols),
        else => opres.classify(op, null),
    };
}

/// Result of expanding a label-style lexeme into its symbol-table
/// key. Local labels (`.foo`) get prefixed with the most recent
/// global label; `owned == true` means the caller frees `key`.
const ResolvedKey = struct {
    key: []const u8,
    owned: bool,
};

/// If `name` starts with `.`, mangle it to `parent.name` using
/// `scratch`; otherwise return the name verbatim (borrowed).
/// Returns an error if a local label appears with no enclosing
/// parent — caller can fall back to a plain lookup.
fn resolveLabelKey(name: []const u8, parent: ?[]const u8, scratch: std.mem.Allocator) !ResolvedKey {
    if (name.len > 0 and name[0] == '.') {
        const p = parent orelse return error.NoParentLabel;
        const joined = try std.fmt.allocPrint(scratch, "{s}{s}", .{ p, name });
        return .{ .key = joined, .owned = true };
    }
    return .{ .key = name, .owned = false };
}

/// Pick the narrowest immediate kind that fits the folded value.
/// Forward refs (anything that doesn't fold) keep the wider
/// `.imm16` so layout sizing stays safe; `resolve()`'s widening
/// pass picks up the wider shape if no `.imm8` form exists.
fn narrowImm(e: *ast.Expr, source: []const u8, symbols: symtab.SymbolTable) opres.Kind {
    var consts = symbols.toConstantTable() catch return .imm16;
    defer consts.deinit();
    return switch (expr.evalExpr(e, source, consts)) {
        .ok => |v| if (v <= 0xFF) .imm8 else .imm16,
        .err => .imm16,
    };
}

// ---------- pass 1: layout ----------

fn layoutPass(
    symbols: *symtab.SymbolTable,
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    tree: parser_mod.ParseTree,
    layout: *Layout,
) !void {
    var current_bank: ?u8 = null;
    var parent_label: ?[]const u8 = null;
    for (tree.program.statements) |stmt| {
        const cursor_ptr = try layoutCursor(layout, current_bank);
        switch (stmt) {
            .label => |l| {
                const name = source[l.name.start..l.name.end];
                const addr: u16 = bankAddr(current_bank, cursor_ptr.*);
                if (name.len > 0 and name[0] == '.') {
                    // Local label: register as `parent.name`.
                    if (parent_label) |p| {
                        const qualified = try std.fmt.allocPrint(symbols.allocator, "{s}{s}", .{ p, name });
                        symbols.putOwned(qualified, .{ .kind = .label, .value = addr, .bank = current_bank }) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.Duplicate => {
                                symbols.allocator.free(qualified);
                                try errors.append(symbols.allocator, .{
                                    .code = .duplicate_label,
                                    .parse_error = core.parseError(
                                        "codegen",
                                        l.name.start,
                                        "duplicate local label",
                                        .{ .expected = "unique local-label name within the enclosing global label", .actual = name, .kind = .semantic },
                                    ),
                                });
                            },
                        };
                    } else {
                        try errors.append(symbols.allocator, .{
                            .code = .undefined_symbol,
                            .parse_error = core.parseError(
                                "codegen",
                                l.name.start,
                                "local label has no enclosing global label",
                                .{ .expected = "preceding global label", .actual = name, .kind = .semantic },
                            ),
                        });
                    }
                } else {
                    symbols.putBorrowed(name, .{ .kind = .label, .value = addr, .bank = current_bank }) catch |err| switch (err) {
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
                    parent_label = name;
                }
            },
            .const_decl => |c| {
                // The parser already evaluated and stored this in
                // its internal ConstantTable, but that table got
                // dropped at end-of-parse. Re-eval here against
                // the symbol table we're building up.
                // On eval failure we stay silent: the parser
                // already surfaced the same diagnostic when it
                // tried to fold this expression. Re-raising would
                // duplicate the user-facing error.
                const name = source[c.name.start..c.name.end];
                var consts = try symbols.toConstantTable();
                defer consts.deinit();
                switch (expr.evalExpr(c.expr, source, consts)) {
                    .ok => |v| symbols.putBorrowed(name, .{ .kind = .const_value, .value = v }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // safety: const_value never triggers Duplicate per putBorrowed's rules
                        error.Duplicate => unreachable,
                    },
                    .err => {},
                }
            },
            .data8, .data16 => |d| {
                const name = source[d.name.start..d.name.end];
                const addr: u16 = bankAddr(current_bank, cursor_ptr.*);
                symbols.putBorrowed(name, .{ .kind = .data, .value = addr, .bank = current_bank }) catch |err| switch (err) {
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
                cursor_ptr.* += try sizeOfDataValues(d.values, word_size, source, symbols, errors);
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
                    // Validate that `target` falls inside the
                    // current section's CPU-address range:
                    //   - base image  → [$0000..$BFFF]
                    //   - any `bank N` → [$C000..$FEFF] (the window)
                    // Mixing them is almost always a user mistake
                    // (writes get shadowed at runtime, or labels
                    // resolve to the wrong CPU space) so we reject
                    // with E007 rather than silently clamping.
                    const in_window = target >= bank_window_base and target <= 0xFEFF;
                    const valid = if (current_bank == null) (target < bank_window_base) else in_window;
                    if (!valid) {
                        try errors.append(symbols.allocator, .{
                            .code = .addr_out_of_range,
                            .parse_error = core.parseError(
                                "org",
                                o.span.start,
                                if (current_bank == null)
                                    "`org` in base image must target $0000..$BFFF (anything in $C000..$FEFF is shadowed by the bank window at runtime)"
                                else
                                    "`org` inside `bank N` must target the bank window $C000..$FEFF",
                                .{ .expected = "address in current section's range", .kind = .semantic },
                            ),
                        });
                    } else {
                        const base = bankAddr(current_bank, 0);
                        const target_offset: u32 = target - base;
                        if (target_offset < cursor_ptr.*) {
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
                            cursor_ptr.* = target_offset;
                        }
                    }
                }
                // If `o.addr` is null the parser already emitted
                // a diagnostic. Leave the cursor alone.
            },
            .bank_switch => |b| {
                if (b.index) |idx| {
                    current_bank = idx;
                    if (layout.max_bank == null or idx > layout.max_bank.?) layout.max_bank = idx;
                    // Touch the cursor entry so the bank slot exists
                    // even if no bytes get emitted into it.
                    _ = try layoutCursor(layout, idx);
                }
            },
            .sram_banks_decl => |s| {
                if (s.count) |n| {
                    layout.sram_banks = n;
                    layout.sram_banks_span = s.span;
                }
            },
            .instruction => |i| {
                const mnem = source[i.mnemonic.start..i.mnemonic.end];
                // Pseudo-instructions desugar to a 2-instruction
                // sequence (4-byte `mov` + 3-byte `call`/`jmp`).
                // Layout cost is fixed at 7 bytes regardless of
                // which bank the target lives in; the actual bank
                // lookup happens in the emit pass.
                if (isBankPseudo(mnem)) {
                    cursor_ptr.* += 7;
                } else {
                    var kinds: [3]opres.Kind = undefined;
                    for (i.operands, 0..) |op, idx| kinds[idx] = classifyForLayout(op, source, symbols.*, parent_label, symbols.allocator);
                    if (opres.resolve(mnem, kinds[0..i.operands.len])) |res| {
                        cursor_ptr.* += res.size;
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
                        cursor_ptr.* += 1;
                    }
                }
            },
            .cond_directive, .comment, .unknown => {},
        }
    }
}

/// E017 — enforce the loader's invariant (`sram_bank_count <=
/// bank_count`) at codegen time. Without this check, writing
/// `sram_banks $01` without any `bank $XX` produces an image whose
/// header fails `vm.parseGx` with `error.InvalidSramCount`, which
/// the `gero asm`/`gero build` CLIs then trip over with a panic.
/// Catching it here turns the failure into a normal caret-rendered
/// diagnostic on the offending directive.
fn validateSramBanks(
    errors: *std.ArrayList(include.Diagnostic),
    layout: *const Layout,
    allocator: std.mem.Allocator,
) !void {
    if (layout.sram_banks == 0) return;
    // @as: widen u8 → u16 so `m + 1` for a max-index of 255 fits without wrap.
    const bank_count: u16 = if (layout.max_bank) |m| @as(u16, m) + 1 else 0;
    if (layout.sram_banks <= bank_count) return;
    // Span fallback: a stray `sram_banks` with no count (parse
    // failure upstream) already raised a parser diagnostic and
    // never updates the span — bail out so we don't double-report
    // with a meaningless caret.
    const span = layout.sram_banks_span orelse return;
    try errors.append(allocator, .{
        .code = .sram_without_banks,
        .parse_error = core.parseError(
            "sram_banks",
            span.start,
            "`sram_banks` count exceeds declared `bank` count — SRAM banks live in the trailing slots of the cart, so add at least one `bank $XX` directive per SRAM bank",
            .{ .expected = "at least one `bank $XX` directive per SRAM bank", .kind = .semantic },
        ),
    });
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
    emit: *Emit,
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    tree: parser_mod.ParseTree,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
    layout: *const Layout,
) !void {
    var current_bank: ?u8 = null;
    var parent_label: ?[]const u8 = null;
    for (tree.program.statements) |stmt| {
        const image = try emitBuffer(allocator, emit, current_bank);
        switch (stmt) {
            .label => |l| {
                const name = source[l.name.start..l.name.end];
                if (name.len == 0 or name[0] != '.') parent_label = name;
            },
            .const_decl, .struct_decl, .sram_banks_decl, .cond_directive, .comment, .unknown => {},
            .bank_switch => |b| {
                if (b.index) |idx| current_bank = idx;
            },
            .data8, .data16 => |d| {
                const word_size: u32 = if (stmt == .data8) 1 else 2;
                try emitDataValues(allocator, image, errors, source, d.values, word_size, consts, symbols);
            },
            .org => |o| {
                if (o.addr) |target| {
                    // Layout already rejected `org` targets outside
                    // the current section's range with E007; skip
                    // the pad logic for those cases so we don't
                    // emit spurious zeros.
                    const in_window = target >= bank_window_base and target <= 0xFEFF;
                    const valid = if (current_bank == null) (target < bank_window_base) else in_window;
                    if (valid) {
                        const base = bankAddr(current_bank, 0);
                        const target_offset: u32 = target - base;
                        while (image.items.len < target_offset) {
                            try image.append(allocator, 0);
                        }
                    }
                    // Backward / out-of-range cases already
                    // diagnosed in pass 1.
                }
            },
            .instruction => |i| {
                try emitInstruction(allocator, image, errors, source, i, consts, symbols, parent_label);
            },
        }
    }
    // Pad each bank up to its layout-pass target (covers any
    // forward-`org` padding that didn't trigger from data/instr).
    const base_target = layout.base_size;
    while (emit.base.items.len < base_target) try emit.base.append(allocator, 0);
    var it = emit.banks.iterator();
    while (it.next()) |entry| {
        const target = layout.bank_sizes.get(entry.key_ptr.*) orelse 0;
        while (entry.value_ptr.items.len < target) try entry.value_ptr.append(allocator, 0);
    }
}

fn emitDataValues(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    values: []const ast.DataValue,
    word_size: u32,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
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
                    .note = symbols.suggestSimilar(name),
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
    parent_label: ?[]const u8,
) !void {
    const mnem = source[inst.mnemonic.start..inst.mnemonic.end];

    // `bank_call <label>` / `bank_jump <label>` — pseudo-instructions
    // that desugar to `mov $bank, mb` + `call`/`jmp <addr>` (7 bytes
    // total). The assembler looks up which bank `<label>` was
    // defined in (via Symbol.bank) so the user doesn't have to
    // hand-track bank-of-target across the codebase.
    if (isBankPseudo(mnem)) {
        try emitBankPseudo(allocator, image, errors, source, inst, mnem, consts, symbols, parent_label);
        return;
    }

    var kinds: [3]opres.Kind = undefined;
    for (inst.operands, 0..) |op, idx| kinds[idx] = classifyForEmit(op, source, symbols.*, parent_label, allocator);
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

    for (inst.operands, 0..) |op, op_idx| switch (op) {
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
            // Resolved shape decides the on-wire width: imm8 → 1 byte,
            // imm16 → 2 bytes (default).
            const width: u32 = if (res.kinds[op_idx] == .imm8) 1 else 2;
            try emitValue(allocator, image, val, width);
        },
        .addr_lit => |a| {
            // ZP-classified addr_lit emits as 1 byte (zero-page form);
            // otherwise the regular 2-byte address encoding.
            const width: u32 = if (res.kinds[op_idx] == .zp) 1 else 2;
            try emitValue(allocator, image, a.value, width);
        },
        .sym_ref => |s| try emitSymRef(allocator, image, errors, source, s, consts, symbols),
        .label_ref => |l| {
            const width: u32 = if (res.kinds[op_idx] == .imm8) 1 else 2;
            try emitLabelRef(allocator, image, errors, source, l, consts, width, parent_label, symbols);
        },
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
        .cast => |c| try emitCast(allocator, image, errors, source, c, consts, symbols),
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
        .reg_offset => |r| {
            const offset_eval = expr.evalExpr(r.offset, source, consts);
            const offset_word: u16 = switch (offset_eval) {
                .ok => |v| v,
                .err => |d| blk: {
                    try errors.append(allocator, d);
                    break :blk 0;
                },
            };
            // Range-check the signed byte representation: value
            // must fit in i8 (−128..+127). u16 representation:
            // 0..0x7F or 0xFF80..0xFFFF (the negative-wrapped form).
            const in_range = (offset_word <= 0x7F) or (offset_word >= 0xFF80);
            if (!in_range) {
                try errors.append(allocator, .{
                    .code = .addr_out_of_range,
                    .parse_error = core.parseError(
                        "codegen",
                        r.span.start,
                        "register-relative offset out of range (-128..+127)",
                        .{ .expected = "signed imm8", .actual = "", .kind = .semantic },
                    ),
                });
            }
            try image.append(allocator, @intFromEnum(r.reg.id));
            // safety: truncating to u8 captures the sign-extended low
            //         byte; out-of-range values were diagnosed above.
            const offset_byte: u8 = @truncate(offset_word);
            try image.append(allocator, offset_byte);
        },
    };
}

/// Emit a `bank_call` / `bank_jump` pseudo-instruction as a
/// `mov $bank, mb` + `call`/`jmp <addr>` pair. The target label
/// must be a defined label (the symbol table carries the bank
/// the label lives in). Always emits 7 bytes — even when the
/// target is in the same bank as the call site, the `mov` runs
/// (no surprise omission). A later optimization could elide the
/// redundant `mov` for same-bank targets.
fn emitBankPseudo(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    inst: ast.Instruction,
    mnem: []const u8,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
    parent_label: ?[]const u8,
) !void {
    _ = consts;

    // Operand shape: exactly one .label_ref or .sym_ref. Anything
    // else → E003. Emit 7 bytes of `hlt` so the cursor stays
    // aligned with the layout pass's assumption.
    if (inst.operands.len != 1) {
        try errors.append(allocator, .{
            .code = .operand_type_mismatch,
            .parse_error = core.parseError(
                "codegen",
                inst.mnemonic.start,
                "operand type mismatch",
                .{ .expected = "exactly one label operand", .actual = mnem, .kind = .semantic },
            ),
        });
        try image.appendNTimes(allocator, 0xFF, 7);
        return;
    }

    const op_span: ast.Span = switch (inst.operands[0]) {
        .label_ref => |l| l.span,
        .sym_ref => |s| s.span,
        else => {
            try errors.append(allocator, .{
                .code = .operand_type_mismatch,
                .parse_error = core.parseError(
                    "codegen",
                    inst.mnemonic.start,
                    "bank_call / bank_jump operand must be a label reference",
                    .{ .expected = "label or @symbol", .actual = mnem, .kind = .semantic },
                ),
            });
            try image.appendNTimes(allocator, 0xFF, 7);
            return;
        },
    };

    var raw_lex = source[op_span.start..op_span.end];
    if (raw_lex.len > 0 and raw_lex[0] == '@') raw_lex = raw_lex[1..];
    const resolved = resolveLabelKey(raw_lex, parent_label, allocator) catch {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .parse_error = core.parseError(
                "codegen",
                op_span.start,
                "local label reference has no enclosing global label",
                .{ .expected = "preceding global label", .actual = raw_lex, .kind = .semantic },
            ),
        });
        try image.appendNTimes(allocator, 0xFF, 7);
        return;
    };
    defer if (resolved.owned) allocator.free(resolved.key);

    const sym = symbols.get(resolved.key) orelse {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .note = symbols.suggestSimilar(resolved.key),
            .parse_error = core.parseError(
                "codegen",
                op_span.start,
                "undefined symbol",
                .{ .expected = "defined label", .actual = resolved.key, .kind = .semantic },
            ),
        });
        try image.appendNTimes(allocator, 0xFF, 7);
        return;
    };

    // bank_call / bank_jump want a label (or data) — they're
    // bank-positioned. Compile-time const_value and struct_field
    // entries have no bank, so reject them.
    if (sym.kind != .label and sym.kind != .data) {
        try errors.append(allocator, .{
            .code = .operand_type_mismatch,
            .parse_error = core.parseError(
                "codegen",
                op_span.start,
                "bank_call / bank_jump target must be a label or data symbol (not a const)",
                .{ .expected = "label or data symbol", .actual = resolved.key, .kind = .semantic },
            ),
        });
        try image.appendNTimes(allocator, 0xFF, 7);
        return;
    }

    // Bank value for the `mov $bank, mb` step. A symbol in the
    // base image (bank = null) gets `$00` — explicit reset rather
    // than skip.
    // @as: widen Symbol.bank (u8) into the u16 we need for `mov imm16`.
    const bank_value: u16 = if (sym.bank) |b| @as(u16, b) else 0;

    // 1. mov $bank, mb — opcode 0x10 (movImm16Reg), imm16 LE,
    //    register 0x0C (mb).
    try image.append(allocator, 0x10);
    try emitValue(allocator, image, bank_value, 2);
    try image.append(allocator, 0x0C);

    // 2. call/jmp <addr> — opcode 0x80 / 0x70, addr LE.
    const jump_opcode: u8 = if (std.mem.eql(u8, mnem, "bank_call")) 0x80 else 0x70;
    try image.append(allocator, jump_opcode);
    try emitValue(allocator, image, sym.value, 2);
}

fn emitSymRef(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    s: ast.SymRef,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
) !void {
    const lex = source[s.span.start..s.span.end];
    const name = if (lex.len > 0 and lex[0] == '@') lex[1..] else lex;
    if (consts.get(name)) |val| {
        try emitValue(allocator, image, val, 2);
    } else {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .note = symbols.suggestSimilar(name),
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
    width: u32,
    parent_label: ?[]const u8,
    symbols: *const symtab.SymbolTable,
) !void {
    const lex = source[l.span.start..l.span.end];
    const resolved = resolveLabelKey(lex, parent_label, allocator) catch {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .parse_error = core.parseError(
                "codegen",
                l.span.start,
                "local label reference has no enclosing global label",
                .{ .expected = "preceding global label", .actual = lex, .kind = .semantic },
            ),
        });
        try emitValue(allocator, image, 0, width);
        return;
    };
    defer if (resolved.owned) allocator.free(resolved.key);
    if (consts.get(resolved.key)) |val| {
        try emitValue(allocator, image, val, width);
    } else {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .note = symbols.suggestSimilar(resolved.key),
            .parse_error = core.parseError(
                "codegen",
                l.span.start,
                "undefined symbol",
                .{ .expected = "defined label / const", .actual = resolved.key, .kind = .semantic },
            ),
        });
        try emitValue(allocator, image, 0, width);
    }
}

fn emitCast(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    errors: *std.ArrayList(include.Diagnostic),
    source: []const u8,
    c: ast.CastOperand,
    consts: expr.ConstantTable,
    symbols: *const symtab.SymbolTable,
) !void {
    // `<Type> @sym.field` desugars to `@sym + Type.field`.
    const sym_lex = source[c.sym_ref.span.start..c.sym_ref.span.end];
    const sym_name = if (sym_lex.len > 0 and sym_lex[0] == '@') sym_lex[1..] else sym_lex;
    const type_name = source[c.type_name.start..c.type_name.end];
    const field_name = source[c.field_name.start..c.field_name.end];

    const sym_val: u16 = if (consts.get(sym_name)) |v| v else blk: {
        try errors.append(allocator, .{
            .code = .undefined_symbol,
            .note = symbols.suggestSimilar(sym_name),
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
            .note = symbols.suggestSimilar(qualified),
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

fn buildArchive(
    allocator: std.mem.Allocator,
    emit: *const Emit,
    layout: *const Layout,
    entry_point: u16,
    symbols: *const symtab.SymbolTable,
    debug_symbols: bool,
) ![]u8 {
    // Header layout per ISA §7.1:
    //   0x00..0x04  magic = "GERO"
    //   0x04..0x06  u16le version = 0x0001
    //   0x06..0x08  u16le flags
    //   0x08..0x0A  u16le entry_point
    //   0x0A..0x0C  u16le image_size      (base image only)
    //   0x0C        u8 bank_count
    //   0x0D        u8 sram_bank_count
    //   0x0E..0x10  reserved (must be 0)
    //
    // Archive body per ISA §7.1 / §7.3:
    //   header + base_image + (bank_count × bank_disk_size) + debug_section?
    //
    // SRAM banks are NOT emitted — they're zero-init at boot.
    const header_size: usize = 16;
    const base_len = emit.base.items.len;

    // 0-based banks: bank_count = max_bank + 1 when any bank was
    // declared, else 0.
    // @as: widen u8 to u16 so the `+ 1` for a max-index of 255 fits.
    const bank_count: u16 = if (layout.max_bank) |m| @as(u16, m) + 1 else 0;
    // @as: widen u16 / u32 to usize for the byte-count math (max 256 × 16 KiB = 4 MiB).
    const banked_bytes: usize = @as(usize, bank_count) * @as(usize, bank_disk_size);

    // Collect debug-symbol entries (sorted by address). When
    // disabled or empty the blob stays empty + the flag bit is
    // not set.
    var debug_entries: std.ArrayList(DebugEntry) = .empty;
    defer debug_entries.deinit(allocator);
    if (debug_symbols) try collectDebugSymbols(allocator, symbols, &debug_entries);

    const debug_bytes_len: usize = debugSectionByteSize(debug_entries.items);
    const total = header_size + base_len + banked_bytes + debug_bytes_len;
    var out = try allocator.alloc(u8, total);

    // Flags per ISA §7.1: bit 0 = banked, bit 1 = has-debug.
    const flag_banked: u16 = 0x0001;
    const flag_has_debug: u16 = 0x0002;
    var flags: u16 = 0;
    if (bank_count > 0) flags |= flag_banked;
    if (debug_bytes_len > 0) flags |= flag_has_debug;

    @memcpy(out[0..4], &gx_magic);
    writeU16Le(out[4..6], 0x0001); // version
    writeU16Le(out[6..8], flags);
    writeU16Le(out[8..10], entry_point);
    // safety: base image capped at 64 KiB by the ISA's 16-bit
    //         address space; banks live in their own segment.
    writeU16Le(out[10..12], @intCast(base_len));
    // safety: bank_count <= 256 by construction (u8 input + at most +1).
    out[12] = @intCast(bank_count);
    out[13] = layout.sram_banks;
    writeU16Le(out[14..16], 0); // reserved

    // Base image.
    @memcpy(out[header_size..][0..base_len], emit.base.items);

    // Banks 0..max_bank: 16 KB each, zero-padded if the program
    // didn't fill the whole window. Gaps (banks the user skipped)
    // are also zeros.
    var cursor: usize = header_size + base_len;
    var bank: u8 = 0;
    while (bank < bank_count) : (bank += 1) {
        const dst = out[cursor..][0..bank_disk_size];
        @memset(dst, 0);
        if (emit.banks.get(bank)) |b| {
            const n = @min(b.items.len, bank_disk_size);
            @memcpy(dst[0..n], b.items[0..n]);
        }
        cursor += bank_disk_size;
    }

    // Debug-symbol section per ISA §7.3.
    if (debug_bytes_len > 0) writeDebugSection(out[cursor..][0..debug_bytes_len], debug_entries.items);

    return out;
}

/// One row in the debug-symbol section per ISA §7.3: an address,
/// a kind (label vs data), and a name. Names are borrowed from
/// the source or owned keys in the symbol table.
const DebugEntry = struct {
    address: u16,
    /// 0 = code label, 1 = data block. Maps to ISA §7.3.
    kind: u8,
    name: []const u8,
};

/// `kind` byte per ISA §7.3 — keeps the constant out of the
/// codegen body so the disasm side can match.
const debug_kind_label: u8 = 0;
const debug_kind_data: u8 = 1;

/// Walk the symbol table, collect `.label` + `.data` entries
/// (consts and struct fields are values, not addresses — skip),
/// skip local-label mangled names (the `.` character isn't a
/// valid ident in asm so they can't round-trip through the
/// disasm). Sort the result by address ascending.
fn collectDebugSymbols(
    allocator: std.mem.Allocator,
    symbols: *const symtab.SymbolTable,
    out: *std.ArrayList(DebugEntry),
) !void {
    var it = symbols.entries.iterator();
    while (it.next()) |entry| {
        const sym = entry.value_ptr.*;
        const kind: u8 = switch (sym.kind) {
            .label => debug_kind_label,
            .data => debug_kind_data,
            .const_value, .struct_field => continue, // not addresses
        };
        const name = entry.key_ptr.*;
        if (std.mem.indexOfScalar(u8, name, '.') != null) continue;
        if (name.len > 0xFF) continue; // ISA §7.3 caps name_len at u8
        try out.append(allocator, .{ .address = sym.value, .kind = kind, .name = name });
    }
    std.mem.sort(DebugEntry, out.items, {}, struct {
        fn lt(_: void, a: DebugEntry, b: DebugEntry) bool {
            return a.address < b.address;
        }
    }.lt);
}

/// Byte size of the encoded debug section, or 0 when empty.
fn debugSectionByteSize(entries: []const DebugEntry) usize {
    if (entries.len == 0) return 0;
    var n: usize = 2; // symbol_count
    for (entries) |e| n += 2 + 1 + 1 + e.name.len; // addr + kind + len + name
    return n;
}

/// Encode the debug section in-place per ISA §7.3.
fn writeDebugSection(dst: []u8, entries: []const DebugEntry) void {
    // safety: caller passes a buffer sized for at most
    //         `debugSectionByteSize(entries)` — every write is
    //         bounded by entries.len ≤ u16 max.
    writeU16Le(dst[0..2], @intCast(entries.len));
    var cursor: usize = 2;
    for (entries) |e| {
        writeU16Le(dst[cursor..][0..2], e.address);
        dst[cursor + 2] = e.kind;
        // safety: collectDebugSymbols filters out names > 0xFF bytes.
        dst[cursor + 3] = @intCast(e.name.len);
        @memcpy(dst[cursor + 4 ..][0..e.name.len], e.name);
        cursor += 4 + e.name.len;
    }
}

fn writeU16Le(dst: []u8, value: u16) void {
    // safety: caller passes a 2-byte slice — bounds-checked by indexing.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast((value >> 8) & 0xFF);
}
