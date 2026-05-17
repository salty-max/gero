/// Specs for `typecheck/annotations` — the §3.7 annotation
/// validation pipeline. Pure helpers (`findAnnotationSpec`,
/// `targetLabel`, spec-table sanity) get direct unit calls; the
/// arm coverage for `validateAnnotations` / `validateAnnotationArgs`
/// (unknown / bad-target / bad-arg / pow2 / conflict) runs E2E
/// through `gero.lang.typecheck` because each helper takes a
/// `*Checker` plus parsed source. `defHasNoCapture` also rides on
/// the E2E surface — its observable effect is whether the
/// `@no_capture` body emits `E_ANN_CAPTURE_VIOLATION`.
const std = @import("std");
const gero = @import("gero");

const annotations = gero.lang.typechecker.annotations;
const alloc = std.testing.allocator;

// ---------- E2E helpers ----------

/// Assert the typechecker produces zero diagnostics on a
/// self-contained source.
fn expectClean(source: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    if (checked.diagnostics.len > 0) {
        std.debug.print("unexpected typecheck diagnostics for `{s}`:\n", .{source});
        for (checked.diagnostics) |d| std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
    }
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

/// Assert at least one diagnostic with `code` fires.
fn expectCode(source: []const u8, code: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, code)) return;
    }
    std.debug.print("missing diagnostic `{s}` for `{s}`; got:\n", .{ code, source });
    for (checked.diagnostics) |d| {
        std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
    }
    return error.MissingDiagnosticCode;
}

// ---------- module reachability ----------

test "typecheck/annotations: module compiles through the barrel" {
    _ = annotations;
}

// ---------- findAnnotationSpec (pure) ----------

test "typecheck/annotations: findAnnotationSpec returns a spec for every documented annotation" {
    inline for (.{
        "bank",   "zero_page", "addr",       "volatile", "align",
        "inline", "cold",      "no_capture", "noreturn", "interrupt",
        "test",   "bench",     "override",   "final",    "abstract",
        "static", "private",
    }) |name| {
        const spec = annotations.findAnnotationSpec(name);
        try std.testing.expect(spec != null);
        try std.testing.expectEqualStrings(name, spec.?.name);
    }
}

test "typecheck/annotations: findAnnotationSpec returns null for unknown names" {
    try std.testing.expect(annotations.findAnnotationSpec("not_a_real_annotation") == null);
    try std.testing.expect(annotations.findAnnotationSpec("") == null);
    // Case-sensitive lookup — `Bank` is not the same as `bank`.
    try std.testing.expect(annotations.findAnnotationSpec("Bank") == null);
}

test "typecheck/annotations: annotation_specs table is self-consistent" {
    // Every entry has a non-empty name and every name in `conflicts_with`
    // resolves back through `findAnnotationSpec` — catches typos in the
    // conflict-pair table.
    for (&annotations.annotation_specs) |spec| {
        try std.testing.expect(spec.name.len > 0);
        for (spec.conflicts_with) |other| {
            const peer = annotations.findAnnotationSpec(other);
            try std.testing.expect(peer != null);
        }
    }
}

// ---------- targetLabel (pure) ----------

test "typecheck/annotations: targetLabel maps each single-bit target to its lexeme" {
    const T = annotations.T;
    try std.testing.expectEqualStrings("let", annotations.targetLabel(T.LET));
    try std.testing.expectEqualStrings("const", annotations.targetLabel(T.CONST));
    try std.testing.expectEqualStrings("def", annotations.targetLabel(T.DEF));
    try std.testing.expectEqualStrings("class", annotations.targetLabel(T.CLASS));
    try std.testing.expectEqualStrings("struct", annotations.targetLabel(T.STRUCT));
    try std.testing.expectEqualStrings("enum", annotations.targetLabel(T.ENUM));
    try std.testing.expectEqualStrings("class field", annotations.targetLabel(T.CLASS_FIELD));
}

test "typecheck/annotations: targetLabel falls back to `decl` for unknown / combined bits" {
    const T = annotations.T;
    // Combined bits don't map cleanly to a single label.
    try std.testing.expectEqualStrings("decl", annotations.targetLabel(T.LET | T.CONST));
    // 0 and out-of-range bits also fall through.
    try std.testing.expectEqualStrings("decl", annotations.targetLabel(0));
    try std.testing.expectEqualStrings("decl", annotations.targetLabel(1 << 20));
}

// ---------- validateAnnotations: E_ANN_UNKNOWN ----------

test "typecheck/annotations: unknown annotation on def errors with E_ANN_UNKNOWN" {
    try expectCode(
        \\@nope
        \\def f()
        \\end
    , "E_ANN_UNKNOWN");
}

test "typecheck/annotations: unknown annotation on let errors with E_ANN_UNKNOWN" {
    try expectCode(
        \\@nope
        \\let x: i16 = 0
    , "E_ANN_UNKNOWN");
}

// ---------- validateAnnotations: E_ANN_BAD_TARGET ----------

test "typecheck/annotations: @inline on let errors with E_ANN_BAD_TARGET" {
    // `inline` is DEF-only.
    try expectCode(
        \\@inline
        \\let x: i16 = 0
    , "E_ANN_BAD_TARGET");
}

test "typecheck/annotations: @zero_page on def errors with E_ANN_BAD_TARGET" {
    // `zero_page` is LET-only.
    try expectCode(
        \\@zero_page
        \\def f()
        \\end
    , "E_ANN_BAD_TARGET");
}

test "typecheck/annotations: @bank on let accepts (multi-target spec)" {
    // `bank` allows DEF | LET | CONST — exercises the multi-bit `targets`
    // path positively so a regression that drops one bit gets caught.
    try expectClean(
        \\@bank 1
        \\let x: i16 = 0
    );
}

// ---------- validateAnnotationArgs: ArgRule.none ----------

test "typecheck/annotations: marker annotation with args errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@inline 5
        \\def f()
        \\end
    , "E_ANN_BAD_ARG");
}

// ---------- validateAnnotationArgs: ArgRule.int_lit ----------

test "typecheck/annotations: @bank without args errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@bank
        \\def f()
        \\end
    , "E_ANN_BAD_ARG");
}

test "typecheck/annotations: @bank with non-int-lit arg errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@bank "one"
        \\def f()
        \\end
    , "E_ANN_BAD_ARG");
}

// ---------- validateAnnotationArgs: ArgRule.int_lit_pow2 ----------

test "typecheck/annotations: @align with power-of-two value accepts" {
    try expectClean(
        \\@align 4
        \\let x: i16 = 0
    );
}

test "typecheck/annotations: @align with non-power-of-two errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@align 6
        \\let x: i16 = 0
    , "E_ANN_BAD_ARG");
}

test "typecheck/annotations: @align with zero errors with E_ANN_BAD_ARG" {
    // The pow2 rule rejects 0 explicitly (`v <= 0` arm), even though
    // bit-trick would accept it. Boundary check.
    try expectCode(
        \\@align 0
        \\let x: i16 = 0
    , "E_ANN_BAD_ARG");
}

test "typecheck/annotations: @align without args errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@align
        \\let x: i16 = 0
    , "E_ANN_BAD_ARG");
}

test "typecheck/annotations: @align with non-int-lit arg errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@align "8"
        \\let x: i16 = 0
    , "E_ANN_BAD_ARG");
}

// ---------- conflict detection ----------

test "typecheck/annotations: @final + @override conflict errors with E_ANN_CONFLICT" {
    try expectCode(
        \\class A
        \\  @final
        \\  @override
        \\  def m()
        \\  end
        \\end
    , "E_ANN_CONFLICT");
}

test "typecheck/annotations: @abstract + @static conflict errors with E_ANN_CONFLICT" {
    try expectCode(
        \\class A
        \\  @abstract
        \\  @static
        \\  def m()
        \\  end
        \\end
    , "E_ANN_CONFLICT");
}

test "typecheck/annotations: @final alone on a def accepts" {
    // Negative-of-conflict: lone @final emits no E_ANN_CONFLICT.
    try expectClean(
        \\class A
        \\  @final
        \\  def m()
        \\  end
        \\end
    );
}

// ---------- defHasNoCapture (observed via E_ANN_CAPTURE_VIOLATION) ----------

test "typecheck/annotations: defHasNoCapture true ⇒ @no_capture mutation flags E_ANN_CAPTURE_VIOLATION" {
    // The predicate itself is one line; its observable effect is
    // whether the checker arms the no-capture state for the body.
    // A successful flag means `defHasNoCapture(d)` returned `true`
    // for this def.
    try expectCode(
        \\@no_capture
        \\def f()
        \\  let x: i16 = 0
        \\  let g = lambda ()
        \\    x = x + 1
        \\  end
        \\end
    , "E_ANN_CAPTURE_VIOLATION");
}

test "typecheck/annotations: defHasNoCapture false ⇒ same body accepts without the annotation" {
    // Without `@no_capture`, the same closure shape must clean —
    // confirms `defHasNoCapture` is reading the annotation list and
    // not unconditionally arming the flag.
    try expectClean(
        \\def f()
        \\  let x: i16 = 0
        \\  let g = lambda ()
        \\    x = x + 1
        \\  end
        \\end
    );
}
