/// Gero-lang — high-level language that compiles to gero
/// bytecode. Public barrel; module internals live under
/// `src/lang/`.
///
/// Per [gero-lang spec](../docs/gero-lang.md).
const std = @import("std");
const lexer_mod = @import("lang/lexer.zig");
const ast_mod = @import("lang/ast.zig");
const parser_mod = @import("lang/parser.zig");

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
