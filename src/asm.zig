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

/// Lexer token.
pub const Token = lexer.Token;
/// Lexer output.
pub const TokenStream = lexer.TokenStream;
/// Tokenize `.gas` source.
pub const tokenize = lexer.tokenize;

/// One file's contribution to the fused source buffer.
pub const FileInfo = include.FileInfo;
/// Fused-offset → (file, file_offset) resolver.
pub const SourceMap = include.SourceMap;
/// Lookup result from `SourceMap.lookup`.
pub const Located = include.Located;
/// Diagnostic carrying a fused-buffer byte offset.
pub const Diagnostic = include.Diagnostic;
/// Asm spec §7 error codes (E001..E016).
pub const ErrorCode = include.ErrorCode;
/// Result of `resolveIncludes`: fused source + source map + errors.
pub const FusedSource = include.FusedSource;
/// Walk the include graph; return one fused source string.
pub const resolveIncludes = include.resolveIncludes;
/// Format a `Diagnostic` as `<path>:<line>:<col>: [Exxx] <msg>`.
pub const formatDiagnostic = include.formatDiagnostic;
/// Pretty-format a `Diagnostic` with a caret-style snippet.
pub const formatPretty = include.formatPretty;
/// Like `formatPretty` but without the path prefix.
pub const formatPrettyBody = include.formatPrettyBody;
/// ANSI escape strings used by the pretty formatter.
pub const Style = include.Style;

/// Source span: `{start, end}` byte offsets in the fused source.
pub const Span = ast_mod.Span;
/// Top-level AST node: label, directive, instruction.
pub const Statement = ast_mod.Statement;
/// Label-statement AST.
pub const Label = ast_mod.Label;
/// Catch-all for unrecognized statement shapes.
pub const Unknown = ast_mod.Unknown;
/// Parsed program: owned `[]Statement`.
pub const Program = ast_mod.Program;
/// Parser output: program AST + diagnostics.
pub const ParseTree = parser.ParseTree;
/// Parse a fused source string into a `ParseTree`.
pub const parse = parser.parse;

/// Compile-time expression AST root.
pub const Expr = ast_mod.Expr;
/// `const` declaration AST.
pub const ConstDecl = ast_mod.ConstDecl;
/// `data8` / `data16` declaration AST.
pub const DataDecl = ast_mod.DataDecl;
/// One entry in a `data8`/`data16` value list.
pub const DataValue = ast_mod.DataValue;
/// Address literal `&FFFF`.
pub const AddrLit = ast_mod.AddrLit;
/// Symbol reference `@sym`.
pub const SymRef = ast_mod.SymRef;
/// String literal `"..."` (data8 only).
pub const StringLit = ast_mod.StringLit;
/// `reserve N` form.
pub const ReserveForm = ast_mod.ReserveForm;
/// `struct` directive AST.
pub const StructDecl = ast_mod.StructDecl;
/// One field of a struct declaration.
pub const StructField = ast_mod.StructField;
/// Field type: `u8` or `u16` (asm spec §2.2).
pub const FieldType = ast_mod.FieldType;
/// `org $ADDR` directive AST.
pub const OrgDecl = ast_mod.OrgDecl;
/// Instruction AST: mnemonic + operands.
pub const Instruction = ast_mod.Instruction;
/// One operand of an instruction.
pub const Operand = ast_mod.Operand;
/// Register reference (`r1`, `acu`, …).
pub const RegisterRef = ast_mod.RegisterRef;
/// Canonical register enum (alias for `vm.Register`).
pub const Register = gero.vm.Register;
/// Indirect-via-register `[r1]`.
pub const IndirectReg = ast_mod.IndirectReg;
/// Bare identifier in operand position (label / const).
pub const LabelRef = ast_mod.LabelRef;
/// `&[expr]` compile-time address operand.
pub const AddrExpr = ast_mod.AddrExpr;
/// `[addr + reg]` indexed-addressing operand.
pub const IndexedAddr = ast_mod.IndexedAddr;
/// `<Type> @sym.field` cast operand.
pub const CastOperand = ast_mod.CastOperand;

/// Name → (kind, address) symbol table.
pub const SymbolTable = symtab_mod.SymbolTable;
/// One entry in `SymbolTable`.
pub const Symbol = symtab_mod.Symbol;
/// Symbol classification.
pub const SymbolKind = symtab_mod.SymbolKind;
/// Codegen output: bytes + symbols + errors.
pub const Codegen = codegen_mod.Codegen;
/// Codegen options.
pub const CodegenOptions = codegen_mod.Options;
/// Assemble a parsed program into a `.gx` byte image.
pub const assemble = codegen_mod.assemble;
/// Assemble one inline instruction to raw bytes (lang `asm "..."`).
pub const assembleInstruction = codegen_mod.assembleInstruction;
/// Bytes + diagnostics from `assembleInstruction`.
pub const InlineAsm = codegen_mod.InlineAsm;
/// Canonical-printer options (indent, etc.).
pub const PrintOptions = printer_mod.PrintOptions;
/// Default canonical-printer options.
pub const default_print_options = printer_mod.default_options;
/// Emit an `ast.Program` as canonical `.gas` source.
pub const printProgram = printer_mod.print;

/// Name → `u16` lookup for compile-time constants.
pub const ConstantTable = expr_mod.ConstantTable;
/// Fold an `Expr` tree to a `u16` using a `ConstantTable`.
pub const evalExpr = expr_mod.evalExpr;
/// Evaluator outcome: ok value or diagnostic.
pub const EvalResult = expr_mod.EvalResult;

/// Errors the smoke assembler can emit.
pub const AsmError = error{
    /// Source didn't match the smoke grammar.
    ParseFailed,
};

/// Smoke assembler: matches `hlt` and returns a one-byte image
/// containing `0xFF`. Caller owns the returned slice.
pub fn assembleHlt(
    allocator: std.mem.Allocator,
    source: []const u8,
) (std.mem.Allocator.Error || AsmError)![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    const result = knit.str("hlt").run(trimmed, allocator);
    switch (result) {
        .ok => |ok| {
            if (ok.index != trimmed.len) return error.ParseFailed;
            const buf = try allocator.alloc(u8, 1);
            buf[0] = 0xFF;
            return buf;
        },
        .err => return error.ParseFailed,
    }
}
