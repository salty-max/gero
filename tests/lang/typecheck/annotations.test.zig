/// Mirror-layout placeholder. Real coverage of annotation
/// validation — unknown / bad-target / bad-arg / pow2 / conflict
/// arms — is gero-qa's design space.
const gero = @import("gero");

test "typecheck/annotations: module compiles through the barrel" {
    _ = gero.lang.typechecker.annotations;
}
