import XCTest
@testable import TakoCoreUI

/// A gate on the shader source itself.
///
/// The whole-frame pixel proof only covers passes that a test frame actually
/// puts on screen. This covers the rest: it fails if any vertex entry point
/// ever reaches clip space without going through the one shared transform,
/// which is where the grid's translation is applied. A new pass that computed
/// its own position would render correctly at rest and tear away from the
/// frame the moment anything scrolled -- the kind of defect that shows up in
/// someone's hands rather than in a test.
final class ShaderTransformGateTests: XCTestCase {
    private func shaderSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/Resources/TerminalShaders.metal")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testEveryVertexEntryPointGoesThroughTheSharedTransform() throws {
        let source = try shaderSource()
        let lines = source.components(separatedBy: .newlines)

        let vertexEntryPoints = lines.filter { $0.hasPrefix("vertex ") }.count
        XCTAssertGreaterThan(vertexEntryPoints, 0, "no vertex entry points found; the gate is not looking at the shader")

        // Every place a clip-space position is produced.
        let positionAssignments = lines.filter { $0.contains(".position = ") }
        XCTAssertEqual(
            positionAssignments.count, vertexEntryPoints,
            "there are \(vertexEntryPoints) vertex entry points but "
            + "\(positionAssignments.count) position assignments; one pass "
            + "produces its position somewhere this gate cannot see")

        for assignment in positionAssignments {
            XCTAssertTrue(
                assignment.contains("terminalDrawableToClip("),
                "a vertex pass sets .position without the shared transform, so "
                + "it will not move with the rest of the frame: \(assignment.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// The translation must be applied inside the shared transform, not by its
    /// callers -- otherwise "every pass calls it" stops meaning "every pass
    /// moves".
    func testTheSharedTransformIsWhereTheTranslationIsApplied() throws {
        let source = try shaderSource()
        guard let start = source.range(of: "inline float4 terminalDrawableToClip("),
              let end = source.range(of: "}", range: start.upperBound..<source.endIndex) else {
            return XCTFail("the shared transform is not in the shader")
        }
        let body = String(source[start.upperBound..<end.lowerBound])
        XCTAssertTrue(
            body.contains("_offsetPad.x"),
            "the vertical translation is not applied inside the shared transform")
    }
}
