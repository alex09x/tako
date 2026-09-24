import Foundation
import XCTest
@testable import TakoCoreUI

final class TerminalCheckpointRestoreCoverageTests: XCTestCase {
    func testTerminalCheckpointRestorePropertiesAndEquality() {
        let restore1 = TerminalCheckpointRestore(
            version: 1,
            cols: 80,
            rows: 24,
            payloadLength: 1024,
            epoch: 42
        )
        XCTAssertEqual(restore1.version, 1)
        XCTAssertEqual(restore1.cols, 80)
        XCTAssertEqual(restore1.rows, 24)
        XCTAssertEqual(restore1.payloadLength, 1024)
        XCTAssertEqual(restore1.epoch, 42)

        let restore2 = TerminalCheckpointRestore(
            version: 1,
            cols: 80,
            rows: 24,
            payloadLength: 1024,
            epoch: 42
        )
        XCTAssertEqual(restore1, restore2)

        let restore3 = TerminalCheckpointRestore(
            version: 2,
            cols: 120,
            rows: 40,
            payloadLength: 2048,
            epoch: 43
        )
        XCTAssertNotEqual(restore1, restore3)
    }

    func testTerminalCheckpointImportError() {
        let error = TerminalCheckpointImportError.shutDown
        XCTAssertEqual(error, .shutDown)
        let asError: Error = error
        XCTAssertTrue(asError is TerminalCheckpointImportError)
    }

    func testTerminalCheckpointFailureClassification() {
        let unsupported = TerminalCheckpointFailure(TakoCheckpointError.UnsupportedVersion(version: 5))
        XCTAssertEqual(unsupported, .unsupportedVersion(version: 5))
        XCTAssertTrue(unsupported.isRecoverableByNegotiation)

        let corrupt = TerminalCheckpointFailure(TakoCheckpointError.Corrupt(reason: "checksum mismatch"))
        XCTAssertEqual(corrupt, .corrupt(reason: "checksum mismatch"))
        XCTAssertFalse(corrupt.isRecoverableByNegotiation)

        let tooLarge = TerminalCheckpointFailure(TakoCheckpointError.TooLarge(size: 2048, limit: 1024))
        XCTAssertEqual(tooLarge, .tooLarge(size: 2048, limit: 1024))
        XCTAssertFalse(tooLarge.isRecoverableByNegotiation)

        let nullArg = TerminalCheckpointFailure(TakoCheckpointError.NullArgument)
        XCTAssertEqual(nullArg, .nullArgument)
        XCTAssertFalse(nullArg.isRecoverableByNegotiation)

        let shutDown = TerminalCheckpointFailure(TerminalCheckpointImportError.shutDown)
        XCTAssertEqual(shutDown, .shutDown)
        XCTAssertFalse(shutDown.isRecoverableByNegotiation)

        struct CustomError: Error, CustomDebugStringConvertible {
            var debugDescription: String { "custom error occurred" }
        }
        let other = TerminalCheckpointFailure(CustomError())
        guard case .other(let desc) = other else {
            XCTFail("Expected .other failure but got \(other)")
            return
        }
        XCTAssertTrue(desc.contains("custom error occurred"), "Expected description to reflect error, got: \(desc)")
        XCTAssertFalse(other.isRecoverableByNegotiation)
    }
}
