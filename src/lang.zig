/// Gero-lang — high-level language that compiles to gero
/// bytecode. Public barrel; module internals live under
/// `src/lang/`.
///
/// Per [gero-lang spec](../docs/gero-lang.md).
const std = @import("std");
const lexer_mod = @import("lang/lexer.zig");

/// Re-export: lexer token.
pub const Token = lexer_mod.Token;
/// Re-export: lexer output stream.
pub const TokenStream = lexer_mod.TokenStream;
/// Re-export: `.gr` tokenizer.
pub const tokenize = lexer_mod.tokenize;
