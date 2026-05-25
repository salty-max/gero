/// Compile-time evaluator for `bake def` / `bake do` bodies per
/// spec §3.8. The typechecker has already enforced the structural
/// restrictions (no MMIO, no asm, no non-bake calls, no Vec /
/// class results); this module runs the post-check AST against a
/// `BakeValue` interpreter and serializes the final value into
/// static-data bytes the codegen interns.
///
/// Restricted on purpose: bake bodies are a strict subset of the
/// runtime. No allocator beyond the typecheck arena, no host I/O,
/// no FFI. The interpreter trades runtime efficiency for
/// determinism — `gero check` must produce identical baked bytes
/// across machines and build modes.
const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const diag_mod = @import("diagnostic.zig");

const Diagnostic = diag_mod.Diagnostic;

/// Default upper bound on AST-walk steps per `bake` invocation.
/// One step = one statement walked or one expression evaluated;
/// loops bump the counter per iteration body. 100M matches the
/// spec's stated default budget and runs in ~1s on a developer
/// laptop for sane lookup-table builds.
pub const default_budget: u32 = 100_000_000;

/// One value produced by the bake interpreter. The shape mirrors
/// the spec's "bakeable types" list (§3.8): primitive scalars,
/// `[T; N]` arrays, tuples, and POD structs. Strings live in the
/// usual interned pool — they're represented here as the byte
/// slice the codegen later writes into the data segment.
///
/// `Vec(T)`, classes, references, and function pointers are
/// unrepresentable here; the typechecker rejects them via
/// `predicates.isBakeableType` before the interpreter ever runs.
pub const BakeValue = union(enum) {
    /// 16-bit integer. Sign interpretation follows the value's
    /// declared type at the binding / parameter level; the
    /// interpreter stores the bits without committing to either
    /// signed or unsigned semantics until serialization.
    int_: u16,
    /// Q8.8 fixed-point value — same bit layout as the runtime
    /// `fixed` primitive (ISA §5.4.1).
    fixed_: u16,
    /// `bool` — `false = 0`, `true = 1`.
    bool_: bool,
    /// `nil` — the unit value; mostly returned from blocks that
    /// produce no useful result.
    nil_,
    /// 8-bit byte slot used by `u8` / `i8` / `char`.
    byte: u8,
    /// String literal — points at interned source bytes (the
    /// codegen later interns into its string pool).
    str: []const u8,
    /// Fixed-length array — every element shares a single shape.
    array: []const BakeValue,
    /// Heterogeneous tuple — per-slot shapes recorded inline.
    tuple: []const BakeValue,
    /// POD struct — `fields[i].name` is the source-buffer slice,
    /// `fields[i].value` the bound value.
    struct_: []const Field,

    pub const Field = struct {
        name: []const u8,
        value: BakeValue,
    };
};

/// Errors the bake driver can return. Semantic violations (budget
/// overrun, unbakeable shape, missing binding) land in the
/// `diagnostics` slice on `Result` — only true host failures
/// propagate through the error union.
pub const BakeError = error{OutOfMemory};

/// Outcome of running the interpreter on one `bake def` /
/// `bake do` site. `value` is `null` when evaluation failed; the
/// caller treats that as a hard stop and skips the codegen path.
pub const Result = struct {
    value: ?BakeValue,
    diagnostics: []const Diagnostic,
};

/// Knobs for one interpreter run. The codegen plumbs `budget`
/// through from `CompileOptions` so tests can lower it without
/// touching the global default.
pub const Options = struct {
    budget: u32 = default_budget,
};

/// Walk a `bake def` body against the supplied argument values.
/// Stub for the scaffolding commit — every shape currently
/// returns `E_BAKE_UNSUPPORTED` until subsequent commits wire in
/// arithmetic, control flow, aggregates, and call dispatch.
pub fn evaluateDef(
    allocator: std.mem.Allocator,
    source: []const u8,
    decl: *const ast.DefDecl,
    args: []const BakeValue,
    opts: Options,
) BakeError!Result {
    _ = source;
    _ = args;
    _ = opts;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);
    try diagnostics.append(allocator, .{
        .severity = .fatal,
        .code = "E_BAKE_UNSUPPORTED",
        .message = "bake interpreter scaffolding only — `def`-form evaluation not yet wired",
        .span = decl.name,
    });
    return .{
        .value = null,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

/// Walk a `bake do … end` block. Same scaffolding-stage shape as
/// `evaluateDef` — replaced by the real interpreter in later
/// commits within this PR.
pub fn evaluateDo(
    allocator: std.mem.Allocator,
    source: []const u8,
    do: *const ast.DoExpr,
    opts: Options,
) BakeError!Result {
    _ = source;
    _ = opts;
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);
    try diagnostics.append(allocator, .{
        .severity = .fatal,
        .code = "E_BAKE_UNSUPPORTED",
        .message = "bake interpreter scaffolding only — `do`-form evaluation not yet wired",
        .span = do.span,
    });
    return .{
        .value = null,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}
