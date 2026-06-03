// Compile-time parser for the §3.2.2 format-spec mini-language
// `[[fill]align][0][width][.precision][type]`. Interpolation strings are
// always literals, so the spec is parsed at compile time and packed into
// the `format_spec_to_buf` syscall params (codegen) after the typechecker
// validates it against the value's type.

const std = @import("std");

/// Field alignment. `default` defers to the value type (right for numbers,
/// left for text).
pub const Align = enum { default, left, right, center };

/// Output type. `default` uses the value's natural rendering; the explicit
/// letters mirror the §3.2.2 grammar (`d x X b o s c`).
pub const Type = enum { default, dec, hex_lower, hex_upper, bin, oct, str, char };

/// A parsed format spec.
pub const Spec = struct {
    alignment: Align = .default,
    fill: u8 = ' ',
    zero_pad: bool = false,
    width: u8 = 0,
    precision: ?u8 = null,
    ty: Type = .default,
};

/// Returned when `bytes` isn't a well-formed spec.
pub const ParseError = error{Malformed};

/// Parse `bytes` (the text between `:` and `)` in `$(expr:fmt)`) into a
/// `Spec`. Rejects trailing garbage and out-of-range width / precision.
pub fn parse(bytes: []const u8) ParseError!Spec {
    var s: Spec = .{};
    var i: usize = 0;

    // `[fill]align` — an explicit fill char only when an alignment follows
    // it (`*>5`); otherwise a leading alignment char stands alone (`>5`).
    if (bytes.len >= 2 and isAlign(bytes[1])) {
        s.fill = bytes[0];
        s.alignment = alignOf(bytes[1]);
        i = 2;
    } else if (bytes.len >= 1 and isAlign(bytes[0])) {
        s.alignment = alignOf(bytes[0]);
        i = 1;
    }

    // `[0]` — zero-pad flag (a leading zero before the width digits).
    if (i < bytes.len and bytes[i] == '0') {
        s.zero_pad = true;
        i += 1;
    }

    // `[width]` — decimal digits.
    if (try readUint(bytes, &i)) |w| s.width = w;

    // `[.precision]`.
    if (i < bytes.len and bytes[i] == '.') {
        i += 1;
        s.precision = (try readUint(bytes, &i)) orelse return ParseError.Malformed;
    }

    // `[type]` — a single grammar letter.
    if (i < bytes.len) {
        s.ty = typeOf(bytes[i]) orelse return ParseError.Malformed;
        i += 1;
    }

    if (i != bytes.len) return ParseError.Malformed; // trailing garbage
    return s;
}

fn isAlign(c: u8) bool {
    return c == '<' or c == '>' or c == '^';
}

fn alignOf(c: u8) Align {
    return switch (c) {
        '<' => .left,
        '>' => .right,
        '^' => .center,
        else => .default,
    };
}

fn typeOf(c: u8) ?Type {
    return switch (c) {
        'd' => .dec,
        'x' => .hex_lower,
        'X' => .hex_upper,
        'b' => .bin,
        'o' => .oct,
        's' => .str,
        'c' => .char,
        else => null,
    };
}

/// Read a run of decimal digits at `bytes[i.*]` into a `u8`, advancing `i`.
/// `null` when no digit is present; `Malformed` when the value exceeds 255.
fn readUint(bytes: []const u8, i: *usize) ParseError!?u8 {
    if (i.* >= bytes.len or !std.ascii.isDigit(bytes[i.*])) return null;
    var v: u16 = 0;
    while (i.* < bytes.len and std.ascii.isDigit(bytes[i.*])) : (i.* += 1) {
        v = v * 10 + (bytes[i.*] - '0');
        if (v > 255) return ParseError.Malformed;
    }
    return @intCast(v);
}
