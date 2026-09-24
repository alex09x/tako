import XCTest
@testable import TakoCoreUI

/// A gate on who can write the cadence.
///
/// The reading is evidence of what a display actually did. A consumer able to
/// advance it could forge that evidence -- and permanently, because the
/// strictly-increasing rule would then reject every real presentation behind
/// a forged one. `@testable` sees internal declarations, so no runtime test
/// can tell internal from public here; the source can.
final class PresentationSurfaceVisibilityGateTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TakoCoreUI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let filesHoldingAClock = [
        "PresentationClock.swift",
        "MetalTerminalRenderer.swift",
        "TakoTerminalNSView.swift",
        "TakoTerminalView.swift",
    ]

    func testNothingPublicCanAdvanceTheCadence() throws {
        for file in Self.filesHoldingAClock {
            for line in try source(file).components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("public ") else { continue }
                XCTAssertFalse(
                    trimmed.contains("func record(presentedAt"),
                    "\(file) exposes the mutator publicly: \(trimmed)")
                // The declaration, not a mention: a public getter whose body
                // reads `presentationClock.cadence` is exactly the intended
                // shape, and flagging it would make this gate useless.
                XCTAssertFalse(
                    trimmed.contains("let presentationClock")
                        || trimmed.contains("var presentationClock"),
                    "\(file) hands the clock itself to public consumers, which is "
                    + "the same thing as exposing the mutator: \(trimmed)")
            }
        }
    }

    /// The immutable reading, on the other hand, must stay public -- that is
    /// the whole consumer contract.
    func testTheImmutableReadingStaysPublic() throws {
        for file in ["TakoTerminalNSView.swift", "TakoTerminalView.swift"] {
            let text = try source(file)
            XCTAssertTrue(
                text.contains("public var presentationCadence: TerminalPresentationCadence"),
                "\(file) no longer publishes the cadence snapshot consumers read")
        }
        let clock = try source("PresentationClock.swift")
        XCTAssertTrue(clock.contains("public var cadence: TerminalPresentationCadence"))
        XCTAssertTrue(clock.contains("public struct TerminalPresentationCadence"))
    }
}
