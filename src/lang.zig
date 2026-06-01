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
const include_mod = @import("lang/include.zig");

const tc_mem_builtin = @import("lang/typecheck/mem_builtin.zig");
const tc_stdlib = @import("lang/typecheck/stdlib.zig");
const tc_match = @import("lang/typecheck/match.zig");
const tc_predicates = @import("lang/typecheck/predicates.zig");
const tc_annotations = @import("lang/typecheck/annotations.zig");
const tc_relations = @import("lang/typecheck/relations.zig");
const tc_flow = @import("lang/typecheck/flow.zig");
const tc_suggestions = @import("lang/typecheck/suggestions.zig");
const tc_type_resolve = @import("lang/typecheck/type_resolve.zig");
const tc_fields = @import("lang/typecheck/fields.zig");
const tc_operators = @import("lang/typecheck/operators.zig");
const tc_diagnostics = @import("lang/typecheck/diagnostics.zig");
const tc_decls = @import("lang/typecheck/decls.zig");
const tc_class_check = @import("lang/typecheck/class_check.zig");
const tc_calls = @import("lang/typecheck/calls.zig");
const bake_mod = @import("lang/bake.zig");
const cg_opcodes = @import("lang/codegen/opcodes.zig");
const cg_archive = @import("lang/codegen/archive.zig");
const cg_mem_builtin = @import("lang/codegen/mem_builtin.zig");
const cg_stdlib = @import("lang/codegen/stdlib.zig");
const cg_math_builtin = @import("lang/codegen/math_builtin.zig");
const cg_bank_builtin = @import("lang/codegen/bank_builtin.zig");
const cg_test_builtin = @import("lang/codegen/test_builtin.zig");
const cg_strings = @import("lang/codegen/strings.zig");
const cg_pattern = @import("lang/codegen/pattern.zig");
const cg_expr_emit = @import("lang/codegen/expr.zig");
const cg_control_flow = @import("lang/codegen/control_flow.zig");
const cg_class = @import("lang/codegen/class.zig");
const cg_value_struct = @import("lang/codegen/value_struct.zig");
const cg_inline_call = @import("lang/codegen/inline_call.zig");
const cg_globals = @import("lang/codegen/globals.zig");
const cg_def = @import("lang/codegen/def.zig");
const cg_statements = @import("lang/codegen/statements.zig");
const cg_lambda = @import("lang/codegen/lambda.zig");
const cg_isa = @import("lang/codegen/isa.zig");

// ---------- lexer ----------

/// Lexer token.
pub const Token = lexer_mod.Token;
/// Lexer output stream.
pub const TokenStream = lexer_mod.TokenStream;
/// A captured line comment (`-- …`); carried through to the formatter.
pub const Comment = lexer_mod.Comment;
/// Tokenize `.gr` source.
pub const tokenize = lexer_mod.tokenize;

// ---------- parser ----------

/// AST node types.
pub const ast = ast_mod;
/// Parser output: program + diagnostics.
pub const ParseTree = parser_mod.ParseTree;
/// Parse tokens into an `ast.Program`.
pub const parse = parser_mod.parse;

/// Pretty-print an `ast.Program` to canonical `.gr`.
/// Round-trip safe: `parse(print(parse(s))) == parse(s)`.
pub const print = print_mod.print;

// ---------- include resolver (multi-file `use "..."`) ----------

/// Fused-source output from `resolveUseImports`.
pub const FusedSource = include_mod.FusedSource;
/// Fused offset → (file, file_offset) resolver.
pub const SourceMap = include_mod.SourceMap;
/// One file's metadata in the include graph.
pub const FileInfo = include_mod.FileInfo;
/// Result of `SourceMap.lookup`.
pub const Located = include_mod.Located;
/// One error from include resolution (cycle / depth / not-found).
pub const IncludeError = include_mod.IncludeError;
/// Discriminator for `IncludeError`.
pub const IncludeErrorKind = include_mod.IncludeErrorKind;
/// Walk the `use "..."` graph from `root_path`, returning fused
/// source + source map.
pub const resolveUseImports = include_mod.resolveUseImports;

// ---------- typechecker ----------

/// Typechecker type representation.
pub const types = types_mod;
/// Scope + symbol-table primitives.
pub const scope = scope_mod;
/// Typechecker output: program + diagnostics.
pub const CheckedProgram = typecheck_mod.CheckedProgram;
/// Type-check an `ast.Program`.
pub const typecheck = typecheck_mod.typecheck;
/// `mem.*` stdlib builtin signature.
pub const MemBuiltinSig = tc_mem_builtin.MemBuiltinSig;
/// Look up a `mem.X` builtin by name.
pub const lookupMemBuiltin = tc_mem_builtin.lookupMemBuiltin;
/// Diagnostic shape carried by `CheckedProgram`.
pub const Diagnostic = diag_mod.Diagnostic;
/// Annotated context span on a `Diagnostic`.
pub const SpanLabel = diag_mod.SpanLabel;
/// Diagnostic severity.
pub const Severity = diag_mod.Severity;
/// Diagnostic rendering (pretty + JSON). See `docs/lang-diagnostics.md`.
pub const render = render_mod;

// ---------- codegen ----------

/// Codegen output: `.gx` image + diagnostics.
pub const Compiled = codegen_mod.Compiled;
/// Codegen options (`entry_name`, `debug_symbols`, `optimize`).
pub const CompileOptions = codegen_mod.Options;
/// Build-mode selector for `CompileOptions.optimize`.
pub const Optimize = codegen_mod.Optimize;
/// Errors `compile` can return (semantic errors land in `Compiled.diagnostics`).
pub const CompileError = codegen_mod.CompileError;
/// Compile a `CheckedProgram` to a `.gx` image.
pub const compile = codegen_mod.compile;

// ---------- bake (compile-time evaluator) ----------

/// Compile-time evaluator (spec §3.8).
/// Routes `bake def` and `bake do` through `evaluateDef` / `evaluateDo`;
/// codegen serializes the result into the data segment.
pub const bake = bake_mod;

/// Boot-layout constants (ISA §7).
pub const codegen = struct {
    /// First IVT slot address.
    pub const ivt_base = codegen_mod.ivt_base;
    /// First byte of code emission.
    pub const code_base = codegen_mod.code_base;
    /// First byte of static-data emission.
    pub const data_base = codegen_mod.data_base;
};

// ---------- internal ----------

/// Submodule seams for mirror-layout test reachability.
/// Not stable consumer API — members may change in any minor bump.
pub const internal = struct {
    /// Typecheck submodule seams.
    pub const typechecker = struct {
        /// Stateful resolution + inference walker.
        pub const Checker = typecheck_mod.Checker;
        /// Pure predicates over `types.Type`.
        pub const predicates = tc_predicates;
        /// Annotation validation (§3.7).
        pub const annotations = tc_annotations;
        /// Assignability + cast convertibility.
        pub const relations = tc_relations;
        /// Flow-sensitive helpers (ident name, body exits, finders).
        pub const flow = tc_flow;
        /// `match` exhaustiveness + reachability.
        pub const match = tc_match;
        /// `mem.*` stdlib typecheck dispatch.
        pub const mem_builtin = tc_mem_builtin;
        /// `math.*` / `bank.*` / `test.*` stdlib typecheck dispatch.
        pub const stdlib = tc_stdlib;
        /// "Did you mean…?" Levenshtein-based name suggestions.
        pub const suggestions = tc_suggestions;
        /// `ast.TypeAnn` → `types.Type` resolution.
        pub const type_resolve = tc_type_resolve;
        /// Field + method resolution for structs + classes.
        pub const fields = tc_fields;
        /// Operator type rules (§4.2.1) + `as T` cast checking.
        pub const operators = tc_operators;
        /// Call type-checking: regular, assert builtins, variadic (§4.6.2), bake (§3.8).
        pub const calls = tc_calls;
        /// Diagnostic emission + symbol-suggestion helpers.
        pub const diagnostics = tc_diagnostics;
        /// Pass-1 top-level name registration.
        pub const decls = tc_decls;
        /// `def` / `class` declaration checking + inheritance rules.
        pub const class_check = tc_class_check;
    };

    /// Codegen submodule seams.
    pub const codegen = struct {
        /// Per-fn codegen state (bytecode buffer, locals, diagnostics).
        pub const Emitter = codegen_mod.Emitter;
        /// Unresolved `call addr` site.
        pub const CallPatch = codegen_mod.CallPatch;
        /// One lexical block tracked at codegen time (owns LIFO `defer` list).
        pub const Block = codegen_mod.Block;
        /// One enclosing loop tracked while emitting the body.
        pub const LoopFrame = codegen_mod.LoopFrame;
        /// Opcode / register / syscall byte tables.
        pub const opcodes = cg_opcodes;
        /// `.gx` archive layout helpers.
        pub const archive = cg_archive;
        /// `mem.*` stdlib codegen lowering.
        pub const mem_builtin = cg_mem_builtin;
        /// `math.*` / `bank.*` / `test.*` stdlib call router.
        pub const stdlib = cg_stdlib;
        /// `math.*` stdlib codegen lowering.
        pub const math_builtin = cg_math_builtin;
        /// `bank.*` stdlib codegen lowering.
        pub const bank_builtin = cg_bank_builtin;
        /// `test.*` stdlib codegen lowering.
        pub const test_builtin = cg_test_builtin;
        /// String literal pool + interpolation lowering.
        pub const strings = cg_strings;
        /// `match` pattern-arm test emission.
        pub const pattern = cg_pattern;
        /// Expression lowering.
        pub const expr_emit = cg_expr_emit;
        /// Control-flow lowering (if / while / for / match / break / continue / defer).
        pub const control_flow = cg_control_flow;
        /// Class lowering (vtable + constructor + field rw + method dispatch).
        pub const class = cg_class;
        /// Inline value-struct lowering (construction, field rw, value-copy,
        /// pass-by-value, return-by-value via sret).
        pub const value_struct = cg_value_struct;
        /// Closure lowering (capture analysis, heap promotion, dispatch).
        pub const lambda = cg_lambda;
        /// `@inline` call expansion (body splice + size gate).
        pub const inline_call = cg_inline_call;
        /// Global placement (`@addr` / `@zero_page` / data) + bake-const eval.
        pub const globals = cg_globals;
        /// Per-def emission (prologue + body + epilogue) + call patching.
        pub const def = cg_def;
        /// Leaf statement lowering (let / const / assign / return / print).
        pub const statements = cg_statements;
        /// ISA-instruction emit helpers.
        pub const isa = cg_isa;
    };
};
