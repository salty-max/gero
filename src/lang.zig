/// Gero-lang — high-level language that compiles to gero
/// bytecode. Public barrel; module internals live under
/// `src/lang/`.
///
/// Per [gero-lang spec](../docs/gero-lang.md).
const std = @import("std");
const lexer_mod = @import("lang/lexer.zig");
const ast_mod = @import("lang/ast.zig");
const parser_mod = @import("lang/parser.zig");
const print_mod = @import("lang/print.zig");
const types_mod = @import("lang/types.zig");
const scope_mod = @import("lang/scope.zig");
const typecheck_mod = @import("lang/typecheck.zig");
const diag_mod = @import("lang/diagnostic.zig");
const render_mod = @import("lang/render.zig");
const codegen_mod = @import("lang/codegen.zig");

// Direct submodule imports for the `internal` namespaces below —
// the parent `typecheck.zig` / `codegen.zig` files don't re-export
// these (the aliases are private), so the barrel pulls them
// straight from disk.
const tc_mem_builtin = @import("lang/typecheck/mem_builtin.zig");
const tc_match = @import("lang/typecheck/match.zig");
const tc_predicates = @import("lang/typecheck/predicates.zig");
const tc_annotations = @import("lang/typecheck/annotations.zig");
const tc_relations = @import("lang/typecheck/relations.zig");
const tc_flow = @import("lang/typecheck/flow.zig");
const cg_opcodes = @import("lang/codegen/opcodes.zig");
const cg_archive = @import("lang/codegen/archive.zig");
const cg_mem_builtin = @import("lang/codegen/mem_builtin.zig");
const cg_strings = @import("lang/codegen/strings.zig");
const cg_pattern = @import("lang/codegen/pattern.zig");
const cg_expr_emit = @import("lang/codegen/expr.zig");
const cg_control_flow = @import("lang/codegen/control_flow.zig");

/// Re-export: lexer token.
pub const Token = lexer_mod.Token;
/// Re-export: lexer output stream.
pub const TokenStream = lexer_mod.TokenStream;
/// Re-export: `.gr` tokenizer.
pub const tokenize = lexer_mod.tokenize;

/// Re-export: AST node types.
pub const ast = ast_mod;
/// Re-export: parser output (program + diagnostics).
pub const ParseTree = parser_mod.ParseTree;
/// Re-export: parse a tokenized source into an `ast.Program`.
pub const parse = parser_mod.parse;

/// Re-export: pretty-print an `ast.Program` to canonical `.gr` text.
/// Round-trip safe: `parse(print(parse(s))) == parse(s)`.
pub const print = print_mod.print;

/// Re-export: typechecker type representation (`Type`, `Primitive`,
/// `Array`, etc.).
pub const types = types_mod;
/// Re-export: typechecker scope + symbol-table primitives.
pub const scope = scope_mod;
/// Re-export: typechecker output (program + diagnostics).
pub const CheckedProgram = typecheck_mod.CheckedProgram;
/// Re-export: walk an `ast.Program` through the typechecker.
pub const typecheck = typecheck_mod.typecheck;

/// Typechecker barrel — intentional consumer surface plus an
/// `internal` namespace for the submodule seams.
pub const typechecker = struct {
    /// Typechecker output (program + diagnostics).
    pub const CheckedProgram = typecheck_mod.CheckedProgram;
    /// Walk an `ast.Program` through the typechecker.
    pub const typecheck = typecheck_mod.typecheck;
    /// `mem.*` stdlib builtin signature (lookup return type).
    pub const MemBuiltinSig = tc_mem_builtin.MemBuiltinSig;
    /// `mem.X` lookup by builtin name.
    pub const lookupMemBuiltin = tc_mem_builtin.lookupMemBuiltin;

    /// Internal — submodule seams exposed for mirror-layout test
    /// reachability. Members under `internal` are **not** stable
    /// consumer API and may change in any minor bump.
    pub const internal = struct {
        /// Internal — stateful resolution + inference walker.
        pub const Checker = typecheck_mod.Checker;
        /// Internal — pure predicates over `types.Type`.
        pub const predicates = tc_predicates;
        /// Internal — §3.7 annotation validation pipeline.
        pub const annotations = tc_annotations;
        /// Internal — assignability + cast convertibility relations.
        pub const relations = tc_relations;
        /// Internal — flow-sensitive helpers (ident name, body
        /// exits, named-type / field finders).
        pub const flow = tc_flow;
        /// Internal — `match` exhaustiveness + reachability checks.
        pub const match = tc_match;
        /// Internal — `mem.*` stdlib typecheck dispatch.
        pub const mem_builtin = tc_mem_builtin;
    };
};

/// Re-export: rich diagnostic shape carried by `CheckedProgram`.
pub const Diagnostic = diag_mod.Diagnostic;
/// Re-export: severity classification on a `Diagnostic`.
pub const Severity = diag_mod.Severity;
/// Re-export: diagnostic-rendering primitives (pretty + JSON).
/// Per `docs/lang-diagnostics.md`.
pub const render = render_mod;

/// Codegen barrel — intentional consumer surface (constants
/// `ivt_base` / `code_base` / `data_base`, the `compile` entry,
/// the `Compiled` / `Options` / `CompileError` types) plus an
/// `internal` namespace for the submodule seams.
pub const codegen = struct {
    /// Codegen output (`.gx` image + diagnostics).
    pub const Compiled = codegen_mod.Compiled;
    /// Codegen knobs (`entry_name`, `debug_symbols`).
    pub const Options = codegen_mod.Options;
    /// Errors `compile` can return (host-failure family — semantic
    /// errors land in `Compiled.diagnostics`).
    pub const CompileError = codegen_mod.CompileError;
    /// Walk a `CheckedProgram` through codegen to a `.gx` image.
    pub const compile = codegen_mod.compile;
    /// IVT base address (first IVT slot per ISA §7).
    pub const ivt_base = codegen_mod.ivt_base;
    /// First byte of code emission (above the IVT + low-RAM
    /// scratch).
    pub const code_base = codegen_mod.code_base;
    /// First byte of static-data emission.
    pub const data_base = codegen_mod.data_base;

    /// Internal — submodule seams exposed for mirror-layout test
    /// reachability. Members under `internal` are **not** stable
    /// consumer API and may change in any minor bump.
    pub const internal = struct {
        /// Internal — per-fn codegen state (bytecode buffer,
        /// locals, diagnostic sink).
        pub const Emitter = codegen_mod.Emitter;
        /// Internal — unresolved `call addr` site shape.
        pub const CallPatch = codegen_mod.CallPatch;
        /// Internal — one lexical block tracked at codegen time
        /// (owns the LIFO `defer` list).
        pub const Block = codegen_mod.Block;
        /// Internal — one enclosing loop tracked while emitting the
        /// body (carries break / continue patches).
        pub const LoopFrame = codegen_mod.LoopFrame;
        /// Internal — opcode / register / syscall byte tables
        /// (mirror of `src/vm/opcodes.zig`).
        pub const opcodes = cg_opcodes;
        /// Internal — `.gx` archive layout + small pure helpers.
        pub const archive = cg_archive;
        /// Internal — `mem.*` stdlib codegen lowering.
        pub const mem_builtin = cg_mem_builtin;
        /// Internal — string literal pool + interpolation
        /// lowering.
        pub const strings = cg_strings;
        /// Internal — `match` pattern-arm test emission.
        pub const pattern = cg_pattern;
        /// Internal — expression lowering helpers.
        pub const expr_emit = cg_expr_emit;
        /// Internal — control-flow lowering (if / while / for /
        /// match / break / continue / defer).
        pub const control_flow = cg_control_flow;
    };
};
/// Re-export: codegen output (`.gx` image + diagnostics).
pub const Compiled = codegen_mod.Compiled;
/// Re-export: codegen knobs (`entry_name`, `debug_symbols`).
pub const CompileOptions = codegen_mod.Options;
/// Re-export: walk a `CheckedProgram` through codegen to a `.gx`
/// image.
pub const compile = codegen_mod.compile;
