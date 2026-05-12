/// Assembler — text `.gas` source → `.gx` bytecode. This file
/// is the public barrel; the real parser / codegen lives under
/// `src/asm/` in subsequent issues. For now it exposes a
/// single smoke entry point that recognizes the `hlt` mnemonic
/// and emits a 1-byte program. The smoke proves the `knit`
/// dependency wiring and the assembler → loader → VM path.
const std = @import("std");
const knit = @import("knit");
const gero = @import("gero.zig");
const lexer = @import("asm/lexer.zig");
const include = @import("asm/include.zig");
const ast_mod = @import("asm/ast.zig");
const parser = @import("asm/parser.zig");
const expr_mod = @import("asm/expr.zig");

/// Re-export: lexer token.
pub const Token = lexer.Token;
/// Re-export: lexer output.
pub const TokenStream = lexer.TokenStream;
/// Re-export: `.gas` tokenizer.
pub const tokenize = lexer.tokenize;

/// Re-export: one file's contribution to the fused source buffer.
pub const FileInfo = include.FileInfo;
/// Re-export: fused-offset → (file, file_offset) resolver.
pub const SourceMap = include.SourceMap;
/// Re-export: lookup result from `SourceMap.lookup`.
pub const Located = include.Located;
/// Re-export: diagnostic carrying a fused-buffer byte offset.
pub const Diagnostic = include.Diagnostic;
/// Re-export: result of `resolveIncludes` — fused source + source map + errors.
pub const FusedSource = include.FusedSource;
/// Re-export: walk the include graph, return one fused source string.
pub const resolveIncludes = include.resolveIncludes;
/// Re-export: format one `Diagnostic` as `<path>:<line>:<col>: <msg>`.
pub const formatDiagnostic = include.formatDiagnostic;

/// Re-export: source span — `{start, end}` byte offsets in the fused source.
pub const Span = ast_mod.Span;
/// Re-export: top-level AST node — label, directive, instruction (others land later).
pub const Statement = ast_mod.Statement;
/// Re-export: label-statement AST shape.
pub const Label = ast_mod.Label;
/// Re-export: catch-all node for unrecognized statement shapes.
pub const Unknown = ast_mod.Unknown;
/// Re-export: parsed program — owned `[]Statement`.
pub const Program = ast_mod.Program;
/// Re-export: parser output — program AST + collected diagnostics.
pub const ParseTree = parser.ParseTree;
/// Re-export: parse a fused source string into a `ParseTree`.
pub const parse = parser.parse;

/// Re-export: compile-time expression AST root.
pub const Expr = ast_mod.Expr;
/// Re-export: const declaration AST shape.
pub const ConstDecl = ast_mod.ConstDecl;
/// Re-export: name → u16 lookup for compile-time constants.
pub const ConstantTable = expr_mod.ConstantTable;
/// Re-export: fold an `Expr` tree to a `u16` using a `ConstantTable`.
pub const evalExpr = expr_mod.evalExpr;
/// Re-export: evaluator outcome (ok value or diagnostic).
pub const EvalResult = expr_mod.EvalResult;

/// Errors the assembler can emit. Restricted while the smoke
/// parser is the only producer; the real assembler will grow
/// this set.
pub const AsmError = error{
    /// Source didn't match the smoke grammar.
    ParseFailed,
};

/// Smoke assembler: matches `hlt` (with optional trailing
/// newline / whitespace) and returns a one-byte image
/// containing `0xFF` (the `hlt` opcode). Caller owns the
/// returned slice.
pub fn assembleHlt(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || AsmError)![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const result = knit.str("hlt").run(trimmed, allocator);
    switch (result) {
        .ok => |ok| {
            // The grammar is strictly `hlt` — extra trailing tokens
            // are a parse failure for this smoke.
            if (ok.index != trimmed.len) return error.ParseFailed;
            const buf = try allocator.alloc(u8, 1);
            buf[0] = 0xFF;
            return buf;
        },
        .err => return error.ParseFailed,
    }
}
