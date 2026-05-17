/// Smoke that the control-flow module is reachable through the
/// public codegen barrel. End-to-end coverage of if / while /
/// for / repeat / match / break / continue / defer lives in
/// `tests/lang/codegen.test.zig`.
const std = @import("std");
const gero = @import("gero");

test "codegen/control_flow: module compiles through the barrel" {
    _ = gero.lang.codegen.internal.control_flow;
}
