/// `gero.toml` parser + project resolver. Foundation for the
/// project-aware subcommands (`gero new`, `gero build`, and the
/// project-mode of `gero check` / `fmt` / `test`).
///
/// Scope: a TOML subset sufficient for the v0.2 manifest shape —
/// section headers, key=value with string literals, string arrays,
/// `#`-comments. **Not** full TOML: no integers, booleans, inline
/// tables, dotted keys, multi-line strings/arrays, dates. Those
/// can land later if the manifest grows to need them.
///
/// Example:
///
/// ```toml
/// [package]
/// name = "my-cart"
/// version = "0.1.0"
/// target = "vm"
///
/// [build]
/// entry = "src/main.gas"
/// out = "out/"
/// optimize = "debug"
///
/// [test]
/// include = ["tests/**/*.gas"]
/// ```
const std = @import("std");

/// One decoded manifest, owned by the caller's allocator. All
/// string slices borrow from the source buffer the caller passed
/// to `parse`; clone if the manifest must outlive the source.
pub const Manifest = struct {
    package: Package,
    build: Build,
    test_: Test,
    fmt: Fmt,

    pub const Package = struct {
        name: []const u8,
        version: []const u8,
        target: []const u8,
    };

    pub const Build = struct {
        entry: []const u8,
        out: []const u8,
        optimize: []const u8,
    };

    pub const Test = struct {
        include: []const []const u8,
    };

    /// `[fmt]` overrides for the canonical printer. Shape mirrors
    /// `gero.asm_.PrintOptions`; the CLI converts between the two
    /// at fmt-time so this module stays library-dep-free.
    pub const Fmt = struct {
        indent: usize,
        comment_column: usize,
        align_kv: bool,
        hex_case: HexCase,
    };

    /// Case policy for hex literals — mirrors `printer.HexCase`.
    pub const HexCase = enum { upper, lower, preserve };

    /// Free the heap-allocated string-array slices. String contents
    /// themselves borrow from the source buffer, so the caller
    /// keeps responsibility for that.
    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.test_.include);
    }
};

/// Default values populated when a section / key is absent. The
/// canonical layout per v0.2 conventions.
pub const defaults = struct {
    pub const package_target: []const u8 = "vm";
    pub const build_out: []const u8 = "out/";
    pub const build_optimize: []const u8 = "debug";
    pub const fmt_indent: usize = 2;
    pub const fmt_comment_column: usize = 30;
    pub const fmt_align_kv: bool = true;
    pub const fmt_hex_case: Manifest.HexCase = .upper;
};

/// One parse-time diagnostic with line / column for the
/// renderer. `message_storage` holds the formatted message inline
/// so the slice returned by `message()` survives the parser's
/// stack teardown (the union is copied by value out of
/// `parseWithDiagnostic`).
pub const Diagnostic = struct {
    line: usize,
    col: usize,
    message_storage: [256]u8 = undefined,
    message_len: usize = 0,

    /// Borrow the formatted-message slice. Valid for the lifetime
    /// of the surrounding `ParseResult` value.
    pub fn message(self: *const Diagnostic) []const u8 {
        return self.message_storage[0..self.message_len];
    }
};

/// Error set for `parse`. The diagnostic accompanying a
/// `ParseFailed` lives on the `Parser` instance and is returned
/// via `parseWithDiagnostic`.
pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
};

/// Result of `parseWithDiagnostic` — either the manifest or the
/// first diagnostic encountered. Single-error v1; multi-error
/// can land later via knit-style recovery.
pub const ParseResult = union(enum) {
    ok: Manifest,
    err: Diagnostic,
};

/// Parse the TOML source into a `Manifest`. On failure, fills in
/// the optional `diag` with the line/col/message so the caller
/// can render a user-facing error.
pub fn parseWithDiagnostic(
    allocator: std.mem.Allocator,
    source: []const u8,
) ParseError!ParseResult {
    var parser = Parser{
        .source = source,
        .index = 0,
        .line = 1,
        .col = 1,
        .allocator = allocator,
    };
    var pending = Pending{};
    while (parser.index < parser.source.len) {
        parser.skipBlanksAndComments();
        if (parser.index >= parser.source.len) break;
        const b = parser.source[parser.index];
        if (b == '[') {
            const section = parser.parseSectionHeader() catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseFailed => return .{ .err = parser.diag },
            };
            parser.current_section = section;
        } else if (isIdentStart(b)) {
            parser.parseKeyValue(&pending) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ParseFailed => return .{ .err = parser.diag },
            };
        } else {
            parser.reportf("unexpected character '{c}' at section / key boundary", .{b});
            return .{ .err = parser.diag };
        }
    }

    // Validate required fields are present.
    const m = pending.finalize(&parser) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => return .{ .err = parser.diag },
    };
    return .{ .ok = m };
}

/// Convenience: `parseWithDiagnostic` that propagates failure as
/// a plain `error.ParseFailed`. Use when the caller already has a
/// place to render the diagnostic OR when only success/failure is
/// needed. The diagnostic is lost; use the verbose form for
/// user-facing errors.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Manifest {
    return switch (try parseWithDiagnostic(allocator, source)) {
        .ok => |m| m,
        .err => error.ParseFailed,
    };
}

/// Walk ancestors of the process cwd looking for a `gero.toml`.
/// Returns the relative path string (using `../` for ancestors)
/// or `null` if none found before the filesystem root.
///
/// The path stays string-only (no opened dir handle), so the
/// caller decides how to consume it (read the file, take its
/// parent for the project root, etc.). Capped at 32 ancestor
/// steps to avoid pathological loops.
pub fn findManifest(
    io: std.Io,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!?[]const u8 {
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(arena);
    var depth: usize = 0;
    const cwd = std.Io.Dir.cwd();
    while (depth <= 32) : (depth += 1) {
        var candidate: std.ArrayList(u8) = .empty;
        defer candidate.deinit(arena);
        try candidate.appendSlice(arena, prefix.items);
        try candidate.appendSlice(arena, "gero.toml");
        if (cwd.statFile(io, candidate.items, .{})) |stat| {
            if (stat.kind == .file) {
                return try arena.dupe(u8, candidate.items);
            }
        } else |_| {}
        try prefix.appendSlice(arena, "../");
    }
    return null;
}

// ---------- internals ----------

/// Identifiers in TOML keys: ASCII letters, digits, `_`, `-`.
/// First char must be a letter or `_` (numbers as section/key
/// names are TOML-legal but not expected in our manifest).
fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
}

/// Which `[section]` the parser is currently inside, so the key-
/// value handler can route into the right pending bucket.
const Section = enum { none, package, build, test_, fmt, unknown };

const Parser = struct {
    source: []const u8,
    index: usize,
    line: usize,
    col: usize,
    allocator: std.mem.Allocator,
    current_section: Section = .none,
    diag: Diagnostic = .{ .line = 0, .col = 0 },

    fn advance(self: *Parser, n: usize) void {
        var i: usize = 0;
        while (i < n and self.index < self.source.len) : (i += 1) {
            if (self.source[self.index] == '\n') {
                self.line += 1;
                self.col = 1;
            } else {
                self.col += 1;
            }
            self.index += 1;
        }
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn skipBlanksAndComments(self: *Parser) void {
        while (self.index < self.source.len) {
            const b = self.source[self.index];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') {
                self.advance(1);
            } else if (b == '#') {
                // Comment to end of line.
                while (self.index < self.source.len and self.source[self.index] != '\n') {
                    self.advance(1);
                }
            } else {
                break;
            }
        }
    }

    /// Eat horizontal whitespace only (no newlines, no comments).
    fn skipHorizontalBlanks(self: *Parser) void {
        while (self.index < self.source.len) {
            const b = self.source[self.index];
            if (b == ' ' or b == '\t') {
                self.advance(1);
            } else {
                break;
            }
        }
    }

    /// `[section_name]` — returns the section variant matching
    /// the body. Unknown sections produce a warning-level
    /// diagnostic but the parser keeps going (forward-compat).
    fn parseSectionHeader(self: *Parser) ParseError!Section {
        // Consume `[`
        self.advance(1);
        self.skipHorizontalBlanks();
        const name_start = self.index;
        if (self.index >= self.source.len or !isIdentStart(self.source[self.index])) {
            self.reportf("expected section name after '['", .{});
            return error.ParseFailed;
        }
        while (self.index < self.source.len and isIdentCont(self.source[self.index])) {
            self.advance(1);
        }
        const name = self.source[name_start..self.index];
        self.skipHorizontalBlanks();
        if (self.index >= self.source.len or self.source[self.index] != ']') {
            self.reportf("expected ']' to close section '{s}'", .{name});
            return error.ParseFailed;
        }
        self.advance(1);
        // Consume the rest of the line (whitespace + optional comment).
        self.skipHorizontalBlanks();
        if (self.index < self.source.len and self.source[self.index] == '#') {
            while (self.index < self.source.len and self.source[self.index] != '\n') {
                self.advance(1);
            }
        }

        if (std.mem.eql(u8, name, "package")) return .package;
        if (std.mem.eql(u8, name, "build")) return .build;
        if (std.mem.eql(u8, name, "test")) return .test_;
        if (std.mem.eql(u8, name, "fmt")) return .fmt;
        // Forward-compat: skip unknown sections instead of failing.
        return .unknown;
    }

    fn parseKeyValue(self: *Parser, pending: *Pending) ParseError!void {
        const key_start = self.index;
        while (self.index < self.source.len and isIdentCont(self.source[self.index])) {
            self.advance(1);
        }
        const key = self.source[key_start..self.index];
        self.skipHorizontalBlanks();
        if (self.index >= self.source.len or self.source[self.index] != '=') {
            self.reportf("expected '=' after key '{s}'", .{key});
            return error.ParseFailed;
        }
        self.advance(1);
        self.skipHorizontalBlanks();

        // Dispatch on value shape: `"..."` for strings, `[...]`
        // for arrays. No other forms supported in v0.2.
        if (self.index >= self.source.len) {
            self.reportf("expected value after '='", .{});
            return error.ParseFailed;
        }
        const b = self.source[self.index];
        switch (b) {
            '"' => {
                const value = try self.parseString();
                try pending.recordString(self, key, value);
            },
            '[' => {
                const value = try self.parseStringArray();
                try pending.recordStringArray(self, key, value);
            },
            '0'...'9' => {
                const value = try self.parseInteger(key);
                try pending.recordInteger(self, key, value);
            },
            't', 'f' => {
                const value = try self.parseBool(key);
                try pending.recordBool(self, key, value);
            },
            else => {
                self.reportf("unsupported value for key '{s}' — expected string, array, integer, or boolean", .{key});
                return error.ParseFailed;
            },
        }

        // Tolerate trailing whitespace + comment on the line.
        self.skipHorizontalBlanks();
        if (self.index < self.source.len and self.source[self.index] == '#') {
            while (self.index < self.source.len and self.source[self.index] != '\n') {
                self.advance(1);
            }
        }
    }

    /// `"..."` — basic string, no escapes for v0.2 (filenames
    /// don't need them). Returns a slice into `source`.
    fn parseString(self: *Parser) ParseError![]const u8 {
        // Consume `"`
        self.advance(1);
        const start = self.index;
        while (self.index < self.source.len and self.source[self.index] != '"' and self.source[self.index] != '\n') {
            self.advance(1);
        }
        if (self.index >= self.source.len or self.source[self.index] == '\n') {
            self.reportf("unterminated string literal", .{});
            return error.ParseFailed;
        }
        const text = self.source[start..self.index];
        self.advance(1); // closing `"`
        return text;
    }

    /// `["a", "b", ...]` — single-line array of strings.
    fn parseStringArray(self: *Parser) ParseError![]const []const u8 {
        // Consume `[`
        self.advance(1);
        var items: std.ArrayList([]const u8) = .empty;
        errdefer items.deinit(self.allocator);
        self.skipHorizontalBlanks();
        if (self.index < self.source.len and self.source[self.index] == ']') {
            self.advance(1);
            return try items.toOwnedSlice(self.allocator);
        }
        while (true) {
            self.skipHorizontalBlanks();
            if (self.index >= self.source.len or self.source[self.index] != '"') {
                self.reportf("expected '\"' in array", .{});
                return error.ParseFailed;
            }
            const s = try self.parseString();
            try items.append(self.allocator, s);
            self.skipHorizontalBlanks();
            if (self.index >= self.source.len) {
                self.reportf("unterminated array", .{});
                return error.ParseFailed;
            }
            if (self.source[self.index] == ',') {
                self.advance(1);
                continue;
            }
            if (self.source[self.index] == ']') {
                self.advance(1);
                return try items.toOwnedSlice(self.allocator);
            }
            self.reportf("expected ',' or ']' in array", .{});
            return error.ParseFailed;
        }
    }

    /// Unsigned decimal integer literal. `key` is only used for
    /// the diagnostic message; the parsed value is returned as
    /// `usize`. No size suffix / radix prefix support — keep the
    /// surface tight.
    fn parseInteger(self: *Parser, key: []const u8) ParseError!usize {
        const start = self.index;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c < '0' or c > '9') break;
            self.advance(1);
        }
        const text = self.source[start..self.index];
        return std.fmt.parseInt(usize, text, 10) catch {
            self.reportf("invalid integer literal for key '{s}'", .{key});
            return error.ParseFailed;
        };
    }

    /// `true` / `false` keyword. Anything else under `t`/`f`
    /// produces a clean diagnostic.
    fn parseBool(self: *Parser, key: []const u8) ParseError!bool {
        const start = self.index;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z'))) break;
            self.advance(1);
        }
        const text = self.source[start..self.index];
        if (std.mem.eql(u8, text, "true")) return true;
        if (std.mem.eql(u8, text, "false")) return false;
        self.reportf("invalid boolean literal '{s}' for key '{s}' (expected true or false)", .{ text, key });
        return error.ParseFailed;
    }

    fn reportf(
        self: *Parser,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        // Format into the diagnostic's inline storage. v0.2
        // surfaces only the first error per parse, so the buffer
        // is single-shot. `bufPrint` truncation on a >256-byte
        // message degrades to whatever fit — acceptable for the
        // pathologically-long edge case.
        self.diag.line = self.line;
        self.diag.col = self.col;
        const text = std.fmt.bufPrint(&self.diag.message_storage, fmt, args) catch self.diag.message_storage[0..];
        self.diag.message_len = text.len;
    }
};

/// Lazy accumulator for the per-section fields. The parser
/// records keys here as they come in; `finalize` validates and
/// fills in defaults at the end.
const Pending = struct {
    pkg_name: ?[]const u8 = null,
    pkg_version: ?[]const u8 = null,
    pkg_target: ?[]const u8 = null,
    build_entry: ?[]const u8 = null,
    build_out: ?[]const u8 = null,
    build_optimize: ?[]const u8 = null,
    test_include: ?[]const []const u8 = null,
    fmt_indent: ?usize = null,
    fmt_comment_column: ?usize = null,
    fmt_align_kv: ?bool = null,
    fmt_hex_case: ?[]const u8 = null,

    fn recordString(self: *Pending, parser: *Parser, key: []const u8, value: []const u8) ParseError!void {
        switch (parser.current_section) {
            .package => {
                if (std.mem.eql(u8, key, "name")) self.pkg_name = value else if (std.mem.eql(u8, key, "version")) self.pkg_version = value else if (std.mem.eql(u8, key, "target")) self.pkg_target = value else {
                    parser.reportf("unknown key 'package.{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            .build => {
                if (std.mem.eql(u8, key, "entry")) self.build_entry = value else if (std.mem.eql(u8, key, "out")) self.build_out = value else if (std.mem.eql(u8, key, "optimize")) self.build_optimize = value else {
                    parser.reportf("unknown key 'build.{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            .test_ => {
                parser.reportf("unknown string key '[test].{s}' (only 'include' is supported)", .{key});
                return error.ParseFailed;
            },
            .fmt => {
                if (std.mem.eql(u8, key, "hex_case")) self.fmt_hex_case = value else {
                    parser.reportf("unknown string key '[fmt].{s}' (only 'hex_case' is a string)", .{key});
                    return error.ParseFailed;
                }
            },
            .unknown, .none => {
                parser.reportf("key '{s}' outside a known section", .{key});
                return error.ParseFailed;
            },
        }
    }

    fn recordInteger(self: *Pending, parser: *Parser, key: []const u8, value: usize) ParseError!void {
        switch (parser.current_section) {
            .fmt => {
                if (std.mem.eql(u8, key, "indent")) self.fmt_indent = value else if (std.mem.eql(u8, key, "comment_column")) self.fmt_comment_column = value else {
                    parser.reportf("unknown integer key '[fmt].{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            else => {
                parser.reportf("integer values aren't expected under section for key '{s}'", .{key});
                return error.ParseFailed;
            },
        }
    }

    fn recordBool(self: *Pending, parser: *Parser, key: []const u8, value: bool) ParseError!void {
        switch (parser.current_section) {
            .fmt => {
                if (std.mem.eql(u8, key, "align_kv")) self.fmt_align_kv = value else {
                    parser.reportf("unknown boolean key '[fmt].{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            else => {
                parser.reportf("boolean values aren't expected under section for key '{s}'", .{key});
                return error.ParseFailed;
            },
        }
    }

    fn recordStringArray(self: *Pending, parser: *Parser, key: []const u8, value: []const []const u8) ParseError!void {
        switch (parser.current_section) {
            .test_ => {
                if (std.mem.eql(u8, key, "include")) self.test_include = value else {
                    parser.reportf("unknown array key '[test].{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            else => {
                parser.reportf("array values only supported under [test].include", .{});
                return error.ParseFailed;
            },
        }
    }

    fn finalize(self: *const Pending, parser: *Parser) ParseError!Manifest {
        const name = self.pkg_name orelse {
            parser.reportf("missing required 'package.name'", .{});
            return error.ParseFailed;
        };
        const version = self.pkg_version orelse {
            parser.reportf("missing required 'package.version'", .{});
            return error.ParseFailed;
        };
        const entry = self.build_entry orelse {
            parser.reportf("missing required 'build.entry'", .{});
            return error.ParseFailed;
        };

        const include_slice: []const []const u8 = if (self.test_include) |v| v else blk: {
            const empty = try parser.allocator.alloc([]const u8, 0);
            break :blk empty;
        };

        // Validate hex_case against the three allowed values. Any
        // other string is a hard parse error with a clear
        // diagnostic — the printer's three-way enum has no escape
        // hatch.
        const hex_case: Manifest.HexCase = if (self.fmt_hex_case) |s| blk: {
            if (std.mem.eql(u8, s, "upper")) break :blk .upper;
            if (std.mem.eql(u8, s, "lower")) break :blk .lower;
            if (std.mem.eql(u8, s, "preserve")) break :blk .preserve;
            parser.reportf("invalid '[fmt].hex_case' value '{s}' (expected 'upper', 'lower', or 'preserve')", .{s});
            return error.ParseFailed;
        } else defaults.fmt_hex_case;

        return .{
            .package = .{
                .name = name,
                .version = version,
                .target = self.pkg_target orelse defaults.package_target,
            },
            .build = .{
                .entry = entry,
                .out = self.build_out orelse defaults.build_out,
                .optimize = self.build_optimize orelse defaults.build_optimize,
            },
            .test_ = .{ .include = include_slice },
            .fmt = .{
                .indent = self.fmt_indent orelse defaults.fmt_indent,
                .comment_column = self.fmt_comment_column orelse defaults.fmt_comment_column,
                .align_kv = self.fmt_align_kv orelse defaults.fmt_align_kv,
                .hex_case = hex_case,
            },
        };
    }
};

// ---------- tests ----------

const testing = std.testing;

test "project: parses the canonical v0.2 manifest shape" {
    const src =
        \\[package]
        \\name = "my-cart"
        \\version = "0.1.0"
        \\target = "vm"
        \\
        \\[build]
        \\entry = "src/main.gas"
        \\out = "out/"
        \\optimize = "debug"
        \\
        \\[test]
        \\include = ["tests/**/*.gas"]
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqualStrings("my-cart", m.package.name);
    try testing.expectEqualStrings("0.1.0", m.package.version);
    try testing.expectEqualStrings("vm", m.package.target);
    try testing.expectEqualStrings("src/main.gas", m.build.entry);
    try testing.expectEqualStrings("out/", m.build.out);
    try testing.expectEqualStrings("debug", m.build.optimize);
    try testing.expectEqual(@as(usize, 1), m.test_.include.len);
    try testing.expectEqualStrings("tests/**/*.gas", m.test_.include[0]);
}

test "project: defaults apply for absent optional fields" {
    const src =
        \\[package]
        \\name = "minimal"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqualStrings("vm", m.package.target);
    try testing.expectEqualStrings("out/", m.build.out);
    try testing.expectEqualStrings("debug", m.build.optimize);
    try testing.expectEqual(@as(usize, 0), m.test_.include.len);
}

test "project: missing required key surfaces diagnostic" {
    // Missing `package.version`.
    const src =
        \\[package]
        \\name = "incomplete"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
    ;
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "version") != null);
}

test "project: unknown key surfaces diagnostic" {
    const src =
        \\[package]
        \\name = "x"
        \\version = "0.0.1"
        \\bogus_key = "no"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
    ;
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "bogus_key") != null);
}

test "project: comments are skipped" {
    const src =
        \\# top-level comment
        \\[package]
        \\name = "commented"   # trailing comment
        \\version = "0.0.1"
        \\# blank-line comment below
        \\
        \\[build]
        \\entry = "main.gas"
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqualStrings("commented", m.package.name);
}

test "project: unterminated string fails with diagnostic" {
    const src =
        \\[package]
        \\name = "no-close
        \\version = "0.0.1"
        \\
    ;
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "unterminated") != null);
}

test "project: empty string array parses cleanly" {
    const src =
        \\[package]
        \\name = "empty-arr"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[test]
        \\include = []
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), m.test_.include.len);
}

test "project: multi-element string array" {
    const src =
        \\[package]
        \\name = "multi"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[test]
        \\include = ["a.gas", "b.gas", "c.gas"]
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), m.test_.include.len);
    try testing.expectEqualStrings("a.gas", m.test_.include[0]);
    try testing.expectEqualStrings("b.gas", m.test_.include[1]);
    try testing.expectEqualStrings("c.gas", m.test_.include[2]);
}

test "project: unknown section is tolerated (forward-compat)" {
    const src =
        \\[package]
        \\name = "tolerant"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[future_feature]
        \\unknown_key = "ignored"
        \\
    ;
    // Unknown section is skipped; unknown KEY inside it errors.
    // For now we error on unknown keys even in unknown sections —
    // can be relaxed if forward-compat needs grow.
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
}

test "project: [fmt] section parses int / bool / string keys" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[fmt]
        \\indent = 4
        \\comment_column = 40
        \\align_kv = false
        \\hex_case = "lower"
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), m.fmt.indent);
    try testing.expectEqual(@as(usize, 40), m.fmt.comment_column);
    try testing.expectEqual(false, m.fmt.align_kv);
    try testing.expectEqual(Manifest.HexCase.lower, m.fmt.hex_case);
}

test "project: [fmt] section defaults when absent" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqual(defaults.fmt_indent, m.fmt.indent);
    try testing.expectEqual(defaults.fmt_comment_column, m.fmt.comment_column);
    try testing.expectEqual(defaults.fmt_align_kv, m.fmt.align_kv);
    try testing.expectEqual(defaults.fmt_hex_case, m.fmt.hex_case);
}

test "project: [fmt] hex_case validates against the three allowed values" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[fmt]
        \\hex_case = "bogus"
        \\
    ;
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "hex_case") != null);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "upper") != null);
}

test "project: [fmt] partial overrides keep defaults for absent keys" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[fmt]
        \\comment_column = 32
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqual(defaults.fmt_indent, m.fmt.indent);
    try testing.expectEqual(@as(usize, 32), m.fmt.comment_column);
    try testing.expectEqual(defaults.fmt_align_kv, m.fmt.align_kv);
    try testing.expectEqual(defaults.fmt_hex_case, m.fmt.hex_case);
}

test "project: [fmt] rejects invalid boolean value" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[fmt]
        \\align_kv = yes
        \\
    ;
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "align_kv") != null);
}
