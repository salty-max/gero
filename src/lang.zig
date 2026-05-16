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
