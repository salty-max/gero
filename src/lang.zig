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
    pub const MemBuiltinSig = typecheck_mod.MemBuiltinSig;
    /// `mem.X` lookup by builtin name.
    pub const lookupMemBuiltin = typecheck_mod.lookupMemBuiltin;

    /// Internal — submodule seams exposed for mirror-layout test
    /// reachability. Members under `internal` are **not** stable
    /// consumer API and may change in any minor bump.
    pub const internal = struct {
        /// Internal — stateful resolution + inference walker.
        pub const Checker = typecheck_mod.Checker;
        /// Internal — pure predicates over `types.Type`.
        pub const predicates = typecheck_mod.predicates;
        /// Internal — §3.7 annotation validation pipeline.
        pub const annotations = typecheck_mod.annotations;
        /// Internal — assignability + cast convertibility relations.
        pub const relations = typecheck_mod.relations;
        /// Internal — flow-sensitive helpers (ident name, body
        /// exits, named-type / field finders).
        pub const flow = typecheck_mod.flow;
        /// Internal — `match` exhaustiveness + reachability checks.
        pub const match = typecheck_mod.match;
        /// Internal — `mem.*` stdlib typecheck dispatch.
        pub const mem_builtin = typecheck_mod.mem_builtin;
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
        pub const opcodes = codegen_mod.opcodes;
        /// Internal — `.gx` archive layout + small pure helpers.
        pub const archive = codegen_mod.archive;
        /// Internal — `mem.*` stdlib codegen lowering.
        pub const mem_builtin = codegen_mod.mem_builtin;
        /// Internal — string literal pool + interpolation
        /// lowering.
        pub const strings = codegen_mod.strings;
        /// Internal — `match` pattern-arm test emission.
        pub const pattern = codegen_mod.pattern;
        /// Internal — expression lowering helpers.
        pub const expr_emit = codegen_mod.expr_emit;
        /// Internal — control-flow lowering (if / while / for /
        /// match / break / continue / defer).
        pub const control_flow = codegen_mod.control_flow;
    };
};
/// Re-export: codegen output (`.gx` image + diagnostics).
pub const Compiled = codegen_mod.Compiled;
/// Re-export: codegen knobs (`entry_name`, `debug_symbols`).
pub const CompileOptions = codegen_mod.Options;
/// Re-export: walk a `CheckedProgram` through codegen to a `.gx`
/// image.
pub const compile = codegen_mod.compile;
