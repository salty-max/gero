//! Discovery and execution of annotated `.gr` entry points — the
//! `@test` defs `gero test` runs and the `@bench` defs `gero bench`
//! measures. Both need the same three steps: parse and type-check a
//! module once, find its annotated defs, then lower once per def with
//! that def as the entry point.

const std = @import("std");
const gero = @import("gero");
const term_mod = @import("term.zig");

/// One annotated def found in a `.gr` module.
pub const Entry = struct {
    /// The def's own name — also the display name in runner output.
    name: []const u8,
    /// Source path of the module that declares it.
    file: []const u8,
};

/// A module whose front-end phases ran once, plus the annotated defs
/// it declares. `compileEntry` lowers from here, so the parse and
/// type-check cost is paid per module rather than per entry.
///
/// Always heap-allocated and handled by pointer: `checked.program`
/// points into `tree`, so copying the struct would leave that
/// reference aimed at the old location.
pub const Module = struct {
    path: []const u8,
    fused: gero.lang.FusedSource,
    tree: gero.lang.ParseTree,
    checked: gero.lang.CheckedProgram,
    entries: []Entry,

    pub fn deinit(self: *Module) void {
        self.checked.deinit();
        self.tree.deinit();
        self.fused.deinit();
    }
};

/// Parse + type-check every `.gr` file in `files`, keeping those that
/// declare at least one def annotated `@<annotation>` whose name also
/// matches `pattern`. A file that fails to read or fails its front-end
/// phases is reported through `term` and skipped rather than aborting
/// the run — the other modules' entries are still worth running.
pub fn discover(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    command: []const u8,
    files: []const []const u8,
    annotation: []const u8,
    pattern: ?[]const u8,
) ![]*Module {
    var out: std.ArrayList(*Module) = .empty;
    for (files) |path| {
        if (!std.mem.endsWith(u8, path, ".gr")) continue;

        var fused = gero.lang.resolveUseImports(io, arena, path) catch {
            try term.warn("{s}: skipping {s} (cannot read)", .{ command, path });
            continue;
        };
        if (fused.hasErrors()) {
            try term.warn("{s}: skipping {s} (unresolved imports)", .{ command, path });
            fused.deinit();
            continue;
        }

        var stream = gero.lang.tokenize(arena, fused.source) catch {
            fused.deinit();
            continue;
        };
        defer stream.deinit();

        var tree = gero.lang.parse(arena, fused.source, stream) catch {
            fused.deinit();
            continue;
        };
        if (stream.errors.len > 0 or tree.errors.len > 0) {
            try term.warn("{s}: skipping {s} (parse errors — run `gero check`)", .{ command, path });
            tree.deinit();
            fused.deinit();
            continue;
        }

        var checked = gero.lang.typecheckGraph(arena, fused.source, &tree.program, &fused.import_aliases, .{ .source_map = &fused.source_map, .imports = fused.imports }) catch {
            tree.deinit();
            fused.deinit();
            continue;
        };
        if (checked.hasErrors()) {
            try term.warn("{s}: skipping {s} (type errors — run `gero check`)", .{ command, path });
            checked.deinit();
            tree.deinit();
            fused.deinit();
            continue;
        }

        const entries = try collectEntries(arena, fused.source, &tree.program, annotation, path, pattern);
        if (entries.len == 0) {
            checked.deinit();
            tree.deinit();
            fused.deinit();
            continue;
        }

        // Place the module before wiring `checked.program`, so the
        // reference points at the tree's final address rather than a
        // copy that is about to move.
        const m = try arena.create(Module);
        m.* = .{
            .path = path,
            .fused = fused,
            .tree = tree,
            .checked = checked,
            .entries = entries,
        };
        m.checked.program = &m.tree.program;
        try out.append(arena, m);
    }
    return out.toOwnedSlice(arena);
}

/// Top-level defs carrying `@<annotation>`, in declaration order so
/// the runner's output is stable across runs.
fn collectEntries(
    arena: std.mem.Allocator,
    source: []const u8,
    program: *const gero.lang.ast.Program,
    annotation: []const u8,
    file: []const u8,
    pattern: ?[]const u8,
) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    for (program.statements) |stmt| switch (stmt) {
        .def_decl => |dd| {
            if (!hasAnnotation(source, dd.annotations, annotation)) continue;
            const name = source[dd.name.start..dd.name.end];
            if (pattern) |p| if (std.mem.indexOf(u8, name, p) == null) continue;
            try list.append(arena, .{ .name = name, .file = file });
        },
        else => {},
    };
    return list.toOwnedSlice(arena);
}

fn hasAnnotation(source: []const u8, annotations: []const gero.lang.ast.Annotation, name: []const u8) bool {
    for (annotations) |a| {
        if (std.mem.eql(u8, source[a.name.start..a.name.end], name)) return true;
    }
    return false;
}

/// Lower `module` with `entry_name` as the program's entry point.
/// Returns the `.gx` image, or `null` when codegen reported errors —
/// an annotated def can lower badly on its own even though the module
/// type-checked, and one bad entry shouldn't stop the others.
pub fn compileEntry(
    arena: std.mem.Allocator,
    module: *const Module,
    entry_name: []const u8,
) !?[]const u8 {
    var compiled = gero.lang.compile(arena, module.fused.source, &module.checked, .{
        .entry_name = entry_name,
        .import_aliases = &module.fused.import_aliases,
        .graph = .{ .source_map = &module.fused.source_map, .imports = module.fused.imports },
    }) catch return null;
    defer compiled.deinit();
    if (compiled.hasErrors()) return null;
    return try arena.dupe(u8, compiled.image);
}

/// How a single run of an annotated entry ended.
pub const RunOutcome = enum {
    /// Reached `hlt` — a `@test` that never tripped an assertion.
    halted,
    /// Raised a fault with no handler. For a `@test` that is the
    /// `trap` vector a failed `test.assert_*` / `panic` raises; other
    /// vectors mean the body itself faulted.
    faulted,
    /// Hit a `brk`.
    breakpoint,
    /// Ran past the cycle budget — an unbounded loop in the body.
    timeout,
};

/// Result of running one entry: how it ended, what it printed, and
/// how many cycles it retired.
pub const Run = struct {
    outcome: RunOutcome,
    fault: ?gero.vm.Vector,
    cycles: u64,
};

/// Boot `image` and run it to completion, capturing its output into
/// `out`. `.gr` programs print through host syscalls, so the VM's
/// host writer is wired to the caller's buffer.
pub fn run(
    arena: std.mem.Allocator,
    image: []const u8,
    out: *std.Io.Writer,
    cycle_budget: u64,
) !Run {
    const loaded = try gero.vm.parseGx(image);
    var vm = gero.vm.VM.init(arena);
    defer vm.deinit();
    try vm.boot(arena, loaded);
    vm.host = .{ .out = out };

    var i: u64 = 0;
    while (i < cycle_budget) : (i += 1) {
        switch (gero.vm.step(&vm)) {
            .cont, .branched => continue,
            .halted => return .{ .outcome = .halted, .fault = null, .cycles = vm.cycles },
            .halted_on_fault => return .{ .outcome = .faulted, .fault = vm.last_fault, .cycles = vm.cycles },
            .breakpoint => return .{ .outcome = .breakpoint, .fault = null, .cycles = vm.cycles },
        }
    }
    return .{ .outcome = .timeout, .fault = null, .cycles = vm.cycles };
}
