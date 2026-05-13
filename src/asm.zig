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
const symtab_mod = @import("asm/symtab.zig");
const codegen_mod = @import("asm/codegen.zig");
const opres_mod = @import("asm/opcode_resolver.zig");
const printer_mod = @import("asm/printer.zig");

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
/// Re-export: asm spec §8 error codes (E001..E016) for semantic errors.
pub const ErrorCode = include.ErrorCode;
/// Re-export: result of `resolveIncludes` — fused source + source map + errors.
pub const FusedSource = include.FusedSource;
/// Re-export: walk the include graph, return one fused source string.
pub const resolveIncludes = include.resolveIncludes;
/// Re-export: format one `Diagnostic` as `<path>:<line>:<col>: [Exxx] <msg>`.
pub const formatDiagnostic = include.formatDiagnostic;
/// Re-export: pretty-format a `Diagnostic` with a caret-style snippet.
pub const formatPretty = include.formatPretty;
/// Re-export: `formatPretty` without the path prefix — caller emits a file header.
pub const formatPrettyBody = include.formatPrettyBody;
/// Re-export: ANSI escape strings the formatter wraps around colored pieces.
pub const Style = include.Style;

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
/// Re-export: data8/data16 declaration AST shape (shared between both).
pub const DataDecl = ast_mod.DataDecl;
/// Re-export: one entry in a data8/data16 value list.
pub const DataValue = ast_mod.DataValue;
/// Re-export: address literal `&FFFF`.
pub const AddrLit = ast_mod.AddrLit;
/// Re-export: symbol reference `@sym`.
pub const SymRef = ast_mod.SymRef;
/// Re-export: string literal `"..."` (data8 only).
pub const StringLit = ast_mod.StringLit;
/// Re-export: `reserve N` form.
pub const ReserveForm = ast_mod.ReserveForm;
/// Re-export: struct directive AST shape.
pub const StructDecl = ast_mod.StructDecl;
/// Re-export: one field in a struct declaration.
pub const StructField = ast_mod.StructField;
/// Re-export: field type (u8 / u16) per asm spec §2.2.
pub const FieldType = ast_mod.FieldType;
/// Re-export: `org $ADDR` directive AST shape.
pub const OrgDecl = ast_mod.OrgDecl;
/// Re-export: instruction AST shape (mnemonic + operands).
pub const Instruction = ast_mod.Instruction;
/// Re-export: one operand of an instruction.
pub const Operand = ast_mod.Operand;
/// Re-export: register reference (`r1`, `acu`, ...).
pub const RegisterRef = ast_mod.RegisterRef;
/// Re-export: the canonical register enum (alias for `vm.Register`).
pub const Register = gero.vm.Register;
/// Re-export: indirect-via-register `[r1]`.
pub const IndirectReg = ast_mod.IndirectReg;
/// Re-export: bare identifier in operand position (label / const reference).
pub const LabelRef = ast_mod.LabelRef;
/// Re-export: `&[expr]` compile-time address expression operand (form a).
pub const AddrExpr = ast_mod.AddrExpr;
/// Re-export: `[addr + reg]` indexed addressing operand (form b).
pub const IndexedAddr = ast_mod.IndexedAddr;
/// Re-export: `<Type> @sym.field` cast operand.
pub const CastOperand = ast_mod.CastOperand;

/// Re-export: name → (kind, address) symbol table.
pub const SymbolTable = symtab_mod.SymbolTable;
/// Re-export: one entry in `SymbolTable`.
pub const Symbol = symtab_mod.Symbol;
/// Re-export: symbol classification.
pub const SymbolKind = symtab_mod.SymbolKind;
/// Re-export: codegen output — bytes + symbols + errors.
pub const Codegen = codegen_mod.Codegen;
/// Re-export: codegen options (entry point etc.).
pub const CodegenOptions = codegen_mod.Options;
/// Re-export: assemble a parsed program into a `.gx` byte image.
pub const assemble = codegen_mod.assemble;
/// Re-export: canonical-printer knobs (indent etc.).
pub const PrintOptions = printer_mod.PrintOptions;
/// Re-export: default canonical-printer options.
pub const default_print_options = printer_mod.default_options;
/// Re-export: emit an `ast.Program` as canonical `.gas` source.
pub const printProgram = printer_mod.print;

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
