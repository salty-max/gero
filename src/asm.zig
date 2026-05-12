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

/// Re-export: lexer token.
pub const Token = lexer.Token;
/// Re-export: lexer output.
pub const TokenStream = lexer.TokenStream;
/// Re-export: `.gas` tokenizer.
pub const tokenize = lexer.tokenize;

/// Re-export: one file in the fused image (canonical path + raw content).
pub const FileInfo = include.FileInfo;
/// Re-export: the per-build file registry.
pub const FileTable = include.FileTable;
/// Re-export: diagnostic with originating file pinned.
pub const Diagnostic = include.Diagnostic;
/// Re-export: result of `resolveIncludes` — fused token stream + file table + errors.
pub const FusedSource = include.FusedSource;
/// Re-export: walk the include graph, return a single fused stream.
pub const resolveIncludes = include.resolveIncludes;
/// Re-export: format one `Diagnostic` as `<path>:<line>:<col>: <msg>`.
pub const formatDiagnostic = include.formatDiagnostic;

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
