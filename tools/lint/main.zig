//! Whole-tree lint binary — consolidates the bash `scripts/check-*.sh`
//! suite into one process that reads every `.zig` file once and runs
//! every rule against the in-memory lines.
//!
//! The bash scripts walked the tree per-rule (and check-unused walked
//! it per-declaration), summing to ~4 minutes on the current codebase.
//! This binary aims for ~10s by amortizing I/O across rules.
//!
//! Output format matches the bash scripts byte-for-byte so CI logs
//! and lefthook diagnostics stay diff-able.
//!
//! Lefthook still calls the per-file bash scripts in pre-commit —
//! they're already fast (a single staged file scans in <0.1s) and
//! migrating them off bash is a separate concern.
const std = @import("std");

const Rule = enum {
    strict,
    naming,
    imports,
    docs,
    unused,
    mirror,
    testing_allocator,

    /// Short name the bash scripts use in their reports.
    pub fn label(self: Rule) []const u8 {
        return switch (self) {
            .strict => "strict",
            .naming => "naming",
            .imports => "imports",
            .docs => "docs",
            .unused => "unused",
            .mirror => "mirror",
            .testing_allocator => "testing-allocator",
        };
    }
};

/// One source file held in memory for the lint pass. `content` is the
/// raw bytes; `lines` are zero-allocation slices into `content`.
const File = struct {
    /// Repo-relative path with forward slashes (e.g. `src/lang/lexer.zig`).
    path: []const u8,
    content: []const u8,
    lines: []const []const u8,
};

const Violation = struct {
    file: []const u8,
    line: u32,
    /// Pre-formatted message ready to emit (the script-compat shape is
    /// rule-specific; we let each rule build its own).
    message: []const u8,
    /// Origin rule — used by the summary footer.
    rule: Rule,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const alloc = init.arena.allocator();

    var io_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &io_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // Argv mode: no args → whole-tree walk; positional args → check
    // exactly those files (used by lefthook pre-commit with
    // {staged_files}).
    const args = try init.minimal.args.toSlice(alloc);
    const per_file_mode = args.len > 1;
    var files: std.ArrayList(File) = .empty;
    if (per_file_mode) {
        for (args[1..]) |path| {
            try addOneFile(io, alloc, &files, path);
        }
    } else {
        try collectZigTree(io, alloc, &files, "src");
        try collectZigTree(io, alloc, &files, "apps");
        try collectZigTree(io, alloc, &files, "tests");
    }

    var violations: std.ArrayList(Violation) = .empty;

    // Per-file rules — each iterates the file's lines once. Multiple
    // rules can flag the same line; the printer groups by-rule.
    for (files.items) |f| {
        try checkStrict(alloc, f, &violations);
        try checkNaming(alloc, f, &violations);
        try checkImports(alloc, f, &violations);
        try checkDocs(alloc, f, &violations);
        try checkTestingAllocator(alloc, f, &violations);
    }

    // Cross-file rules — meaningless on a partial file set, so skip
    // them in per-file mode (lefthook pre-commit). The pre-push
    // hook runs `zig build lint` which exercises the whole tree.
    if (!per_file_mode) {
        try checkUnused(alloc, files.items, &violations);
        try checkMirror(alloc, files.items, &violations);
    }

    // Print rule-by-rule so callers can `| grep [strict]` etc., and so
    // the bash-script footer message ("❌ N strict-compiler violations")
    // stays per-rule.
    return try emitReport(stdout, violations.items);
}

// ---------- file collection ----------

/// Load one file by path into the linter's in-memory set. Silently
/// skips non-`.zig` paths and missing files — lefthook may pass
/// staged-and-deleted entries.
fn addOneFile(io: std.Io, alloc: std.mem.Allocator, files: *std.ArrayList(File), path: []const u8) !void {
    if (!std.mem.endsWith(u8, path, ".zig")) return;
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const lines = try splitLines(alloc, content);
    try files.append(alloc, .{
        .path = try alloc.dupe(u8, path),
        .content = content,
        .lines = lines,
    });
}

fn collectZigTree(io: std.Io, alloc: std.mem.Allocator, files: *std.ArrayList(File), root: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        // Some checks accept a missing root (e.g. apps/ on minimal forks).
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const full_path = try std.fs.path.join(alloc, &.{ root, entry.path });
        const content = try dir.readFileAlloc(io, entry.path, alloc, .unlimited);
        const lines = try splitLines(alloc, content);
        try files.append(alloc, .{
            .path = full_path,
            .content = content,
            .lines = lines,
        });
    }
}

fn splitLines(alloc: std.mem.Allocator, content: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\n') {
            try list.append(alloc, content[start..i]);
            start = i + 1;
        }
    }
    if (start < content.len) {
        try list.append(alloc, content[start..]);
    }
    return list.toOwnedSlice(alloc);
}

fn trimWhitespace(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn isPureComment(line: []const u8) bool {
    const trimmed = trimWhitespace(line);
    return std.mem.startsWith(u8, trimmed, "//");
}

/// True when the previous line carries the universal `// allow-strict:`
/// silencer. Several rules also accept rule-specific tokens
/// (`@as:`, `safety:`, etc.) — those are checked via `hasJustification`.
fn isAllowed(prev: []const u8) bool {
    return std.mem.indexOf(u8, prev, "allow-strict:") != null;
}

fn hasJustification(prev: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, prev, needle) != null;
}

fn pushViolation(
    alloc: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    rule: Rule,
    file: []const u8,
    line: u32,
    message: []const u8,
) !void {
    try violations.append(alloc, .{
        .file = file,
        .line = line,
        .message = try alloc.dupe(u8, message),
        .rule = rule,
    });
}

// ---------- strict rules ----------

fn checkStrict(
    alloc: std.mem.Allocator,
    file: File,
    violations: *std.ArrayList(Violation),
) !void {
    // src/-only enforcement.
    if (!std.mem.startsWith(u8, file.path, "src/")) return;

    var prev: []const u8 = "";
    for (file.lines, 0..) |line, idx| {
        const lineno = @as(u32, @intCast(idx + 1));
        const stripped = trimWhitespace(line);
        const is_comment = std.mem.startsWith(u8, stripped, "//");

        // Rule 1: anyerror in code.
        if (!is_comment and std.mem.indexOf(u8, line, "anyerror") != null) {
            if (!isAllowed(prev)) {
                try pushStrict(alloc, violations, file.path, lineno, "anyerror", line);
            }
        }

        // Rule 2: *anyopaque (or *const anyopaque).
        if (!is_comment and
            (std.mem.indexOf(u8, line, "*anyopaque") != null or
                std.mem.indexOf(u8, line, "*const anyopaque") != null))
        {
            if (!isAllowed(prev)) {
                try pushStrict(alloc, violations, file.path, lineno, "anyopaque-banned", line);
            }
        }

        // Rule 3: @as(.
        if (!is_comment and std.mem.indexOf(u8, line, "@as(") != null) {
            if (!isAllowed(prev) and !hasJustification(prev, "@as:")) {
                try pushStrict(alloc, violations, file.path, lineno, "@as-no-comment", line);
            }
        }

        // Rule 4: @ptrCast / @alignCast / @bitCast.
        inline for ([_][]const u8{ "@ptrCast(", "@alignCast(", "@bitCast(" }) |cast| {
            if (!is_comment and std.mem.indexOf(u8, line, cast) != null) {
                if (!isAllowed(prev) and !hasJustification(prev, "safety:")) {
                    const rule_id = comptime cast[0 .. cast.len - 1] ++ "-no-safety-comment";
                    try pushStrict(alloc, violations, file.path, lineno, rule_id, line);
                }
                break;
            }
        }

        // Rule 8 first (catch unreachable shadows rule 5 / 9).
        var is_catch_unreachable = false;
        if (!is_comment and std.mem.indexOf(u8, line, "catch unreachable") != null) {
            is_catch_unreachable = true;
            if (!isAllowed(prev)) {
                try pushStrict(alloc, violations, file.path, lineno, "catch-unreachable", line);
            }
        }

        // Rule 5: bare unreachable (skip lines already covered by rule 8).
        if (!is_catch_unreachable and !is_comment and isWordPresent(line, "unreachable")) {
            const prev_is_comment = std.mem.indexOf(u8, prev, "//") != null;
            if (!isAllowed(prev) and !prev_is_comment) {
                try pushStrict(alloc, violations, file.path, lineno, "unreachable-no-comment", line);
            }
        }

        // Rule 9: `catch |x| return x` — verbose `try`.
        if (!is_comment) {
            if (matchCatchReturnSelf(line)) {
                if (!isAllowed(prev)) {
                    try pushStrict(alloc, violations, file.path, lineno, "catch-return-use-try", line);
                }
            }
        }

        // Rule 10: std.heap.page_allocator direct use.
        if (!is_comment and std.mem.indexOf(u8, line, "page_allocator") != null) {
            if (!isAllowed(prev)) {
                try pushStrict(alloc, violations, file.path, lineno, "page_allocator-direct", line);
            }
        }

        // Rule 11: usingnamespace.
        if (std.mem.startsWith(u8, stripped, "usingnamespace ") or
            std.mem.startsWith(u8, stripped, "pub usingnamespace "))
        {
            if (!isAllowed(prev)) {
                try pushStrict(alloc, violations, file.path, lineno, "usingnamespace-deprecated", line);
            }
        }

        // Rule 12: //! outside src/gero.zig (the public barrel).
        if (std.mem.startsWith(u8, stripped, "//!")) {
            const is_barrel = std.mem.eql(u8, file.path, "src/gero.zig");
            if (!is_barrel and !isAllowed(prev)) {
                try pushStrict(alloc, violations, file.path, lineno, "module-doc-outside-core", line);
            }
        }

        // Rule 6: @compileError("TODO".
        if (!is_comment and std.mem.indexOf(u8, line, "@compileError(\"TODO") != null) {
            const prev_is_comment = std.mem.indexOf(u8, prev, "//") != null;
            if (!isAllowed(prev) and !prev_is_comment) {
                try pushStrict(alloc, violations, file.path, lineno, "compileError-TODO", line);
            }
        }

        // Rule 7: std.debug.print( in src/ (exempt: debug-log.zig).
        if (!is_comment and std.mem.indexOf(u8, line, "std.debug.print(") != null) {
            const exempt = std.mem.eql(u8, file.path, "src/parsers/util/debug-log.zig");
            if (!exempt) {
                try pushStrict(alloc, violations, file.path, lineno, "std.debug.print-in-src", line);
            }
        }

        prev = line;
    }
}

fn pushStrict(
    alloc: std.mem.Allocator,
    violations: *std.ArrayList(Violation),
    file: []const u8,
    line: u32,
    rule_id: []const u8,
    content: []const u8,
) !void {
    const msg = try std.fmt.allocPrint(alloc, "  {s}:{d}: [{s}] {s}", .{ file, line, rule_id, content });
    try violations.append(alloc, .{
        .file = file,
        .line = line,
        .message = msg,
        .rule = .strict,
    });
}

/// True if `needle` appears in `haystack` as a whole word (delimited by
/// non-identifier chars). `unreachable` matches in `catch unreachable`
/// but not inside the identifier `myunreachable`.
fn isWordPresent(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.mem.eql(u8, haystack[i .. i + needle.len], needle)) continue;
        const left_ok = i == 0 or !isIdentChar(haystack[i - 1]);
        const right_ok = i + needle.len == haystack.len or !isIdentChar(haystack[i + needle.len]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn isIdentChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or
        (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or
        b == '_';
}

/// Match `catch |name| return name` — same identifier both sides.
/// Returns true when the suspicious shape is present.
fn matchCatchReturnSelf(line: []const u8) bool {
    // Find "catch |" first.
    var idx = std.mem.indexOf(u8, line, "catch |") orelse return false;
    idx += "catch |".len;

    // Read identifier 1.
    const id1_start = idx;
    while (idx < line.len and isIdentChar(line[idx])) : (idx += 1) {}
    if (idx == id1_start) return false;
    const id1 = line[id1_start..idx];

    // Expect `| `.
    if (idx >= line.len or line[idx] != '|') return false;
    idx += 1;
    while (idx < line.len and line[idx] == ' ') : (idx += 1) {}

    // Expect `return `.
    const want = "return ";
    if (idx + want.len > line.len) return false;
    if (!std.mem.eql(u8, line[idx .. idx + want.len], want)) return false;
    idx += want.len;
    while (idx < line.len and line[idx] == ' ') : (idx += 1) {}

    // Read identifier 2.
    const id2_start = idx;
    while (idx < line.len and isIdentChar(line[idx])) : (idx += 1) {}
    if (idx == id2_start) return false;
    const id2 = line[id2_start..idx];

    return std.mem.eql(u8, id1, id2);
}

// ---------- naming ----------

fn checkNaming(
    alloc: std.mem.Allocator,
    file: File,
    violations: *std.ArrayList(Violation),
) !void {
    var prev: []const u8 = "";
    for (file.lines, 0..) |line, idx| {
        const lineno = @as(u32, @intCast(idx + 1));
        const stripped = trimWhitespace(line);

        if (!std.mem.startsWith(u8, stripped, "pub fn ")) {
            prev = line;
            continue;
        }
        if (!std.mem.endsWith(u8, stripped, "{")) {
            // Multi-line signature — heuristic skip, matching bash.
            prev = line;
            continue;
        }

        // Parse the name after `pub fn `.
        const after_kw = stripped["pub fn ".len..];
        var name_end: usize = 0;
        while (name_end < after_kw.len and isIdentChar(after_kw[name_end])) : (name_end += 1) {}
        if (name_end == 0) {
            prev = line;
            continue;
        }
        const name = after_kw[0..name_end];
        const first = name[0];

        // Detect `) type {` (with optional whitespace) on the same line.
        const is_type_returning = std.mem.indexOf(u8, line, ") type {") != null or
            std.mem.indexOf(u8, line, ") type  {") != null;

        if (is_type_returning) {
            if (first >= 'a' and first <= 'z' and !isAllowed(prev)) {
                const msg = try std.fmt.allocPrint(alloc, "  {s}:{d}: type-returning fn '{s}' should be PascalCase: {s}", .{ file.path, lineno, name, line });
                try violations.append(alloc, .{ .file = file.path, .line = lineno, .message = msg, .rule = .naming });
            }
        } else {
            if (first >= 'A' and first <= 'Z' and !isAllowed(prev)) {
                const msg = try std.fmt.allocPrint(alloc, "  {s}:{d}: fn '{s}' should be camelCase (PascalCase reserved for type-returning fns): {s}", .{ file.path, lineno, name, line });
                try violations.append(alloc, .{ .file = file.path, .line = lineno, .message = msg, .rule = .naming });
            }
        }

        prev = line;
    }
}

// ---------- imports ----------

fn checkImports(
    alloc: std.mem.Allocator,
    file: File,
    violations: *std.ArrayList(Violation),
) !void {
    if (!std.mem.startsWith(u8, file.path, "src/")) return;

    var prev: []const u8 = "";
    for (file.lines, 0..) |line, idx| {
        const lineno = @as(u32, @intCast(idx + 1));
        if (std.mem.indexOf(u8, line, "../../") != null) {
            if (std.mem.indexOf(u8, prev, "allow-import:") == null) {
                const msg = try std.fmt.allocPrint(alloc, "  {s}:{d}: {s}", .{ file.path, lineno, line });
                try violations.append(alloc, .{ .file = file.path, .line = lineno, .message = msg, .rule = .imports });
            }
        }
        prev = line;
    }
}

// ---------- docs ----------

fn checkDocs(
    alloc: std.mem.Allocator,
    file: File,
    violations: *std.ArrayList(Violation),
) !void {
    if (!std.mem.startsWith(u8, file.path, "src/")) return;

    for (file.lines, 0..) |line, idx| {
        const stripped = trimWhitespace(line);

        // Match `pub fn ` / `pub const ` / `pub var `.
        const is_pub_decl =
            std.mem.startsWith(u8, stripped, "pub fn ") or
            std.mem.startsWith(u8, stripped, "pub const ") or
            std.mem.startsWith(u8, stripped, "pub var ");
        if (!is_pub_decl) continue;

        // Walk backward through the contiguous comment block.
        var has_doc = false;
        var has_allow = false;
        var j: isize = @as(isize, @intCast(idx)) - 1;
        while (j >= 0) : (j -= 1) {
            const prev_line = file.lines[@as(usize, @intCast(j))];
            const prev_stripped = trimWhitespace(prev_line);
            if (prev_stripped.len == 0) break;
            if (std.mem.startsWith(u8, prev_stripped, "///")) {
                has_doc = true;
            } else if (std.mem.startsWith(u8, prev_stripped, "//")) {
                if (std.mem.indexOf(u8, prev_stripped, "allow-strict:") != null) {
                    has_allow = true;
                }
            } else {
                break;
            }
        }

        if (!has_doc and !has_allow) {
            const lineno = @as(u32, @intCast(idx + 1));
            const msg = try std.fmt.allocPrint(alloc, "  {s}:{d}: pub declaration missing /// doc comment: {s}", .{ file.path, lineno, line });
            try violations.append(alloc, .{ .file = file.path, .line = lineno, .message = msg, .rule = .docs });
        }
    }
}

// ---------- testing-allocator ----------

fn checkTestingAllocator(
    alloc: std.mem.Allocator,
    file: File,
    violations: *std.ArrayList(Violation),
) !void {
    if (!std.mem.endsWith(u8, file.path, ".test.zig")) return;

    // File-level allowlist.
    if (std.mem.indexOf(u8, file.content, "// allow-test-allocator:") != null) return;

    // Does the file touch allocations?
    const tokens = [_][]const u8{ ".alloc(", ".dupe(", ".create(", ".realloc(", ".free(", "Allocator" };
    var touches_alloc = false;
    for (tokens) |tok| {
        if (std.mem.indexOf(u8, file.content, tok) != null) {
            touches_alloc = true;
            break;
        }
    }
    if (!touches_alloc) return;

    if (std.mem.indexOf(u8, file.content, "std.testing.allocator") == null) {
        const msg = try std.fmt.allocPrint(alloc, "  {s}: alloc-touching test but no std.testing.allocator usage", .{file.path});
        try violations.append(alloc, .{ .file = file.path, .line = 1, .message = msg, .rule = .testing_allocator });
    }
}

// ---------- unused (cross-file) ----------

const PubDecl = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
};

fn checkUnused(
    alloc: std.mem.Allocator,
    files: []const File,
    violations: *std.ArrayList(Violation),
) !void {
    // Pass 1: collect every `pub fn|const|var <name>` in src/ that
    // isn't allowlisted on the line above. Skip allowlisted to avoid
    // counting them as searchable.
    var decls: std.ArrayList(PubDecl) = .empty;
    for (files) |f| {
        if (!std.mem.startsWith(u8, f.path, "src/")) continue;
        for (f.lines, 0..) |line, idx| {
            const name_opt = parsePubName(line);
            if (name_opt == null) continue;
            if (idx > 0 and std.mem.indexOf(u8, f.lines[idx - 1], "allow-unused:") != null) continue;
            try decls.append(alloc, .{
                .name = name_opt.?,
                .file = f.path,
                .line = @as(u32, @intCast(idx + 1)),
            });
        }
    }

    // Pass 2: for each decl, count word-bounded occurrences across
    // src/ + tests/ excluding the defining line. A single hit
    // anywhere means "referenced"; we don't need the full count.
    for (decls.items) |d| {
        var seen: bool = false;
        outer: for (files) |f| {
            const in_search_scope = std.mem.startsWith(u8, f.path, "src/") or
                std.mem.startsWith(u8, f.path, "tests/");
            if (!in_search_scope) continue;
            for (f.lines, 0..) |line, idx| {
                const lineno = @as(u32, @intCast(idx + 1));
                if (std.mem.eql(u8, f.path, d.file) and lineno == d.line) continue;
                if (isWordPresent(line, d.name)) {
                    seen = true;
                    break :outer;
                }
            }
        }
        if (!seen) {
            const msg = try std.fmt.allocPrint(alloc, "  {s}:{d}: {s}", .{ d.file, d.line, d.name });
            try violations.append(alloc, .{ .file = d.file, .line = d.line, .message = msg, .rule = .unused });
        }
    }
}

/// Parse the identifier from a `pub fn|const|var NAME ...` line.
/// Returns null if the line isn't a `pub` declaration of the right
/// shape.
fn parsePubName(line: []const u8) ?[]const u8 {
    const stripped = trimWhitespace(line);
    if (!std.mem.startsWith(u8, stripped, "pub ")) return null;
    var rest = stripped["pub ".len..];

    inline for ([_][]const u8{ "fn ", "const ", "var " }) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) {
            rest = rest[kw.len..];
            var end: usize = 0;
            while (end < rest.len and isIdentChar(rest[end])) : (end += 1) {}
            if (end == 0) return null;
            return rest[0..end];
        }
    }
    return null;
}

// ---------- mirror (cross-file) ----------

fn checkMirror(
    alloc: std.mem.Allocator,
    files: []const File,
    violations: *std.ArrayList(Violation),
) !void {
    // Index by path for O(1) lookup.
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (files) |f| try seen.put(f.path, {});

    // Direction 1: every src/**/*.zig (except exempt) has tests/**/*.test.zig
    for (files) |f| {
        if (!std.mem.startsWith(u8, f.path, "src/")) continue;
        if (isMirrorExempt(f.path)) continue;

        // Build expected mirror path: src/X.zig → tests/X.test.zig.
        const body = f.path["src/".len .. f.path.len - ".zig".len];
        const expected = try std.fmt.allocPrint(alloc, "tests/{s}.test.zig", .{body});
        if (!seen.contains(expected)) {
            const msg = try std.fmt.allocPrint(alloc, "  src has no test mirror: {s} → expected {s}", .{ f.path, expected });
            try violations.append(alloc, .{ .file = f.path, .line = 0, .message = msg, .rule = .mirror });
        }
    }

    // Direction 2: every tests/**/*.test.zig has a src/**/*.zig.
    for (files) |f| {
        if (!std.mem.endsWith(u8, f.path, ".test.zig")) continue;
        if (!std.mem.startsWith(u8, f.path, "tests/")) continue;
        if (std.mem.eql(u8, f.path, "tests/util.zig") or
            std.mem.eql(u8, f.path, "tests/util.test.zig")) continue;

        const body = f.path["tests/".len .. f.path.len - ".test.zig".len];
        const expected = try std.fmt.allocPrint(alloc, "src/{s}.zig", .{body});
        if (!seen.contains(expected)) {
            const msg = try std.fmt.allocPrint(alloc, "  test has no src mirror (orphan): {s} → expected {s}", .{ f.path, expected });
            try violations.append(alloc, .{ .file = f.path, .line = 0, .message = msg, .rule = .mirror });
        }
    }
}

fn isMirrorExempt(path: []const u8) bool {
    // Public barrel.
    if (std.mem.eql(u8, path, "src/gero.zig")) return true;
    // internal.zig anywhere under src/.
    if (std.mem.endsWith(u8, path, "/internal.zig")) return true;
    // Top-level module barrels: src/<name>.zig with no further slash.
    const inside = path["src/".len..];
    if (std.mem.indexOfScalar(u8, inside, '/') == null) return true;
    return false;
}

// ---------- output ----------

/// Print the bash-script-compatible footers for each rule that fired,
/// in source order: strict → naming → imports → docs → testing-
/// allocator → unused → mirror. Returns the exit code (1 on any
/// violation).
fn emitReport(out: *std.Io.Writer, violations: []const Violation) !u8 {
    const rule_order = [_]Rule{ .strict, .naming, .imports, .docs, .testing_allocator, .unused, .mirror };
    var any: bool = false;
    for (rule_order) |rule| {
        var count: u32 = 0;
        for (violations) |v| {
            if (v.rule != rule) continue;
            try out.print("{s}\n", .{v.message});
            count += 1;
        }
        if (count == 0) continue;
        any = true;
        try out.writeAll("\n");
        try emitFooter(out, rule, count);
    }
    return if (any) 1 else 0;
}

fn emitFooter(out: *std.Io.Writer, rule: Rule, count: u32) !void {
    switch (rule) {
        .strict => try out.print(
            "❌ {d} strict-compiler violation(s) found.\n   Allowlist a violation with '// allow-strict: <reason>' on the line above.\n   Or supply the per-rule justification: '// @as: ...' or '// safety: ...'.\n   See CLAUDE.md \"Strict Compiler Configuration\".\n\n",
            .{count},
        ),
        .naming => try out.print(
            "❌ {d} naming-convention violation(s) found.\n   PascalCase for type-returning fns; camelCase otherwise.\n   See CLAUDE.md \"Naming convention\".\n\n",
            .{count},
        ),
        .imports => try out.print(
            "❌ {d} deep relative import(s) found.\n   Single-level '../' is allowed; '../../' and deeper is forbidden.\n   See CLAUDE.md \"Imports\".\n\n",
            .{count},
        ),
        .docs => try out.print(
            "❌ {d} public declaration(s) lack a /// doc comment.\n   Add a one-line /// description directly above the declaration,\n   or allowlist with '// allow-strict: <reason>' if the symbol is\n   not part of the consumer-facing API.\n   See CLAUDE.md \"Doc Comments\".\n\n",
            .{count},
        ),
        .testing_allocator => try out.print(
            "❌ {d} alloc-touching test(s) without std.testing.allocator.\n   Use std.testing.allocator (leak-checked) or allowlist with\n   '// allow-test-allocator: <reason>' if a different allocator is\n   intentional.\n   See CLAUDE.md \"Testing\".\n\n",
            .{count},
        ),
        .unused => try out.print(
            "❌ {d} unused public export(s) found.\n   Either reference them, delete them, or add '// allow-unused: <reason>' above.\n   See CLAUDE.md \"Self-Review / Step 3 — explicit acceptance checks\".\n\n",
            .{count},
        ),
        .mirror => try out.print(
            "❌ {d} mirror violation(s) found.\n   Convention: src/<module>/<path>.zig ↔ tests/<module>/<path>.test.zig\n   See CLAUDE.md \"Source Layout\".\n\n",
            .{count},
        ),
    }
}
