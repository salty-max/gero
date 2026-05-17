/// Mirror-layout placeholder. Behavior coverage is gero-qa's
/// design space.
const gero = @import("gero");

test "typecheck/relations: module compiles through the barrel" {
    _ = gero.lang.typechecker.relations;
}
