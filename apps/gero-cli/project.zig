/// `gero.toml` parser + project resolver. Foundation for the
/// project-aware subcommands (`gero new`, `gero build`, and the
/// project-mode of `gero check` / `fmt` / `test`).
///
/// Scope: a TOML subset sufficient for today's manifest shape —
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
        /// Optional one-line package description. Surfaces in
        /// future tooling (registry, doc generator) — has no
        /// effect on the build today.
        description: ?[]const u8,
        /// Optional SPDX-style license identifier.
        license: ?[]const u8,
        /// Optional canonical repository URL.
        repository: ?[]const u8,
        /// Optional authors — `["Jane Doe <jane@example.com>"]` shape.
        /// Empty slice when absent.
        authors: []const []const u8,
        /// Optional keywords for future search / registry use.
        /// Empty slice when absent.
        keywords: []const []const u8,
    };

    pub const Build = struct {
        entry: []const u8,
        out: []const u8,
        optimize: []const u8,
        /// Output filename stem — the `.gx` lands at
        /// `<out>/<name>.gx`. `null` falls back to `[package].name`
        /// (mirrors Cargo's `[[bin]].name` convention).
        name: ?[]const u8,
        /// Emit a debug-symbol blob into the `.gx` so `gero info` /
        /// `gero disasm` can print friendly names. Defaults to `true`.
        debug_symbols: bool,
    };

    pub const Test = struct {
        include: []const []const u8,
        /// Optional list of manifest-relative paths (file or
        /// directory) to subtract from the discovered include set.
        /// Empty slice when absent.
        exclude: []const []const u8,
        /// Per-test cycle budget enforced by `gero test`. Caps a
        /// buggy program from hanging the runner. Defaults to 1M.
        cycle_budget: usize,
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
        allocator.free(self.test_.exclude);
        allocator.free(self.package.authors);
        allocator.free(self.package.keywords);
    }
};

/// Default values populated when a section / key is absent —
/// the canonical layout.
pub const defaults = struct {
    pub const package_target: []const u8 = "vm";
    pub const build_out: []const u8 = "out/";
    pub const build_optimize: []const u8 = "debug";
    pub const build_debug_symbols: bool = true;
    pub const fmt_indent: usize = 2;
    pub const fmt_comment_column: usize = 30;
    pub const fmt_align_kv: bool = true;
    pub const fmt_hex_case: Manifest.HexCase = .upper;
    pub const test_cycle_budget: usize = 1_000_000;
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
        // for arrays. No other forms supported.
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

    /// `"..."` — basic string, no escapes (filenames don't need
    /// them). Returns a slice into `source`.
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
    /// `usize`. Accepts TOML-style underscore separators
    /// (`1_000_000`) — they're stripped before `parseInt`. No
    /// radix prefix / sign support — keep the surface tight.
    fn parseInteger(self: *Parser, key: []const u8) ParseError!usize {
        const start = self.index;
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if ((c < '0' or c > '9') and c != '_') break;
            self.advance(1);
        }
        const text = self.source[start..self.index];
        // Strip underscores into a stack-local buffer before
        // handing the digits to `parseInt`. Manifest values are
        // short (cycle budgets, columns) — 32 bytes is plenty.
        var scratch: [32]u8 = undefined;
        var n: usize = 0;
        for (text) |c| {
            if (c == '_') continue;
            if (n >= scratch.len) {
                self.reportf("integer literal for key '{s}' is too long", .{key});
                return error.ParseFailed;
            }
            scratch[n] = c;
            n += 1;
        }
        if (n == 0) {
            self.reportf("expected digits in integer literal for key '{s}'", .{key});
            return error.ParseFailed;
        }
        return std.fmt.parseInt(usize, scratch[0..n], 10) catch {
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
        // Format into the diagnostic's inline storage. The parser
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
    pkg_description: ?[]const u8 = null,
    pkg_license: ?[]const u8 = null,
    pkg_repository: ?[]const u8 = null,
    pkg_authors: ?[]const []const u8 = null,
    pkg_keywords: ?[]const []const u8 = null,
    build_entry: ?[]const u8 = null,
    build_out: ?[]const u8 = null,
    build_optimize: ?[]const u8 = null,
    build_name: ?[]const u8 = null,
    build_debug_symbols: ?bool = null,
    test_include: ?[]const []const u8 = null,
    test_exclude: ?[]const []const u8 = null,
    test_cycle_budget: ?usize = null,
    fmt_indent: ?usize = null,
    fmt_comment_column: ?usize = null,
    fmt_align_kv: ?bool = null,
    fmt_hex_case: ?[]const u8 = null,

    fn recordString(self: *Pending, parser: *Parser, key: []const u8, value: []const u8) ParseError!void {
        switch (parser.current_section) {
            .package => {
                if (std.mem.eql(u8, key, "name")) {
                    self.pkg_name = value;
                } else if (std.mem.eql(u8, key, "version")) {
                    self.pkg_version = value;
                } else if (std.mem.eql(u8, key, "target")) {
                    self.pkg_target = value;
                } else if (std.mem.eql(u8, key, "description")) {
                    self.pkg_description = value;
                } else if (std.mem.eql(u8, key, "license")) {
                    self.pkg_license = value;
                } else if (std.mem.eql(u8, key, "repository")) {
                    self.pkg_repository = value;
                } else {
                    parser.reportf("unknown key 'package.{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            .build => {
                if (std.mem.eql(u8, key, "entry")) {
                    self.build_entry = value;
                } else if (std.mem.eql(u8, key, "out")) {
                    self.build_out = value;
                } else if (std.mem.eql(u8, key, "optimize")) {
                    self.build_optimize = value;
                } else if (std.mem.eql(u8, key, "name")) {
                    self.build_name = value;
                } else {
                    parser.reportf("unknown key 'build.{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            .test_ => {
                parser.reportf("unknown string key '[test].{s}' (only 'include' / 'exclude' arrays + 'cycle_budget' are accepted)", .{key});
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
            .test_ => {
                if (std.mem.eql(u8, key, "cycle_budget")) self.test_cycle_budget = value else {
                    parser.reportf("unknown integer key '[test].{s}'", .{key});
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
            .build => {
                if (std.mem.eql(u8, key, "debug_symbols")) self.build_debug_symbols = value else {
                    parser.reportf("unknown boolean key '[build].{s}'", .{key});
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
            .package => {
                if (std.mem.eql(u8, key, "authors")) self.pkg_authors = value else if (std.mem.eql(u8, key, "keywords")) self.pkg_keywords = value else {
                    parser.reportf("unknown array key '[package].{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            .test_ => {
                if (std.mem.eql(u8, key, "include")) self.test_include = value else if (std.mem.eql(u8, key, "exclude")) self.test_exclude = value else {
                    parser.reportf("unknown array key '[test].{s}'", .{key});
                    return error.ParseFailed;
                }
            },
            else => {
                parser.reportf("array values aren't expected under this section for key '{s}'", .{key});
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

        const include_slice: []const []const u8 = if (self.test_include) |v| v else try parser.allocator.alloc([]const u8, 0);
        const exclude_slice: []const []const u8 = if (self.test_exclude) |v| v else try parser.allocator.alloc([]const u8, 0);
        const authors_slice: []const []const u8 = if (self.pkg_authors) |v| v else try parser.allocator.alloc([]const u8, 0);
        const keywords_slice: []const []const u8 = if (self.pkg_keywords) |v| v else try parser.allocator.alloc([]const u8, 0);

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

        // Validate optimize too — it gates the per-profile output
        // subdirectory (`out/<optimize>/...`), so a typo would
        // silently land artifacts in `out/relase/` and confuse the
        // user. Keep the surface in sync with the CLI's
        // `--optimize` enum.
        const optimize = self.build_optimize orelse defaults.build_optimize;
        if (!std.mem.eql(u8, optimize, "debug") and
            !std.mem.eql(u8, optimize, "release") and
            !std.mem.eql(u8, optimize, "size"))
        {
            parser.reportf("invalid '[build].optimize' value '{s}' (expected 'debug', 'release', or 'size')", .{optimize});
            return error.ParseFailed;
        }

        return .{
            .package = .{
                .name = name,
                .version = version,
                .target = self.pkg_target orelse defaults.package_target,
                .description = self.pkg_description,
                .license = self.pkg_license,
                .repository = self.pkg_repository,
                .authors = authors_slice,
                .keywords = keywords_slice,
            },
            .build = .{
                .entry = entry,
                .out = self.build_out orelse defaults.build_out,
                .optimize = optimize,
                .name = self.build_name,
                .debug_symbols = self.build_debug_symbols orelse defaults.build_debug_symbols,
            },
            .test_ = .{
                .include = include_slice,
                .exclude = exclude_slice,
                .cycle_budget = self.test_cycle_budget orelse defaults.test_cycle_budget,
            },
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

test "project: parses the canonical manifest shape" {
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

test "project: [package] metadata fields parse + default to null/empty" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\description = "demo cart"
        \\license = "MIT"
        \\repository = "https://github.com/me/p"
        \\authors = ["Jane Doe <jane@example.com>", "John"]
        \\keywords = ["vm", "demo"]
        \\
        \\[build]
        \\entry = "main.gas"
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqualStrings("demo cart", m.package.description.?);
    try testing.expectEqualStrings("MIT", m.package.license.?);
    try testing.expectEqualStrings("https://github.com/me/p", m.package.repository.?);
    try testing.expectEqual(@as(usize, 2), m.package.authors.len);
    try testing.expectEqualStrings("Jane Doe <jane@example.com>", m.package.authors[0]);
    try testing.expectEqual(@as(usize, 2), m.package.keywords.len);
    try testing.expectEqualStrings("vm", m.package.keywords[0]);
}

test "project: [package] metadata is fully optional" {
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

    try testing.expect(m.package.description == null);
    try testing.expect(m.package.license == null);
    try testing.expect(m.package.repository == null);
    try testing.expectEqual(@as(usize, 0), m.package.authors.len);
    try testing.expectEqual(@as(usize, 0), m.package.keywords.len);
}

test "project: [build].name + debug_symbols override" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\name = "p-cli"
        \\debug_symbols = false
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqualStrings("p-cli", m.build.name.?);
    try testing.expectEqual(false, m.build.debug_symbols);
}

test "project: [build].name defaults to null, debug_symbols to true" {
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

    try testing.expect(m.build.name == null);
    try testing.expectEqual(true, m.build.debug_symbols);
}

test "project: [test] exclude + cycle_budget" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\
        \\[test]
        \\include = ["tests/"]
        \\exclude = ["tests/wip", "tests/skip.gas"]
        \\cycle_budget = 5_000_000
        \\
    ;
    var m = try parse(testing.allocator, src);
    defer m.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), m.test_.exclude.len);
    try testing.expectEqualStrings("tests/wip", m.test_.exclude[0]);
    try testing.expectEqualStrings("tests/skip.gas", m.test_.exclude[1]);
    try testing.expectEqual(@as(usize, 5_000_000), m.test_.cycle_budget);
}

test "project: [test] exclude / cycle_budget default to empty / 1M" {
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

    try testing.expectEqual(@as(usize, 0), m.test_.exclude.len);
    try testing.expectEqual(defaults.test_cycle_budget, m.test_.cycle_budget);
}

test "project: [build].optimize validates against debug | release | size" {
    const src =
        \\[package]
        \\name = "p"
        \\version = "0.0.1"
        \\
        \\[build]
        \\entry = "main.gas"
        \\optimize = "fast"
        \\
    ;
    const result = try parseWithDiagnostic(testing.allocator, src);
    try testing.expect(result == .err);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "optimize") != null);
    try testing.expect(std.mem.indexOf(u8, result.err.message(), "debug") != null);
}
