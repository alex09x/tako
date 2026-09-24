import XCTest
import Foundation
@testable import TakoCoreUI

final class TerminalCheckpointTests: XCTestCase {
    func testCheckpointExportAndVerify() {
        let core = TakoCore(cols: 20, rows: 6)
        core.feed(bytes: Data("Hello, Checkpoint!\r\n".utf8))

        let data = core.checkpoint()
        XCTAssertGreaterThan(data.count, 20)

        // Magic header should be TKCK (0x54, 0x4B, 0x43, 0x4B)
        let magic = Array(data.prefix(4))
        XCTAssertEqual(magic, [0x54, 0x4B, 0x43, 0x4B])

        // verifyCheckpoint on valid payload
        XCTAssertTrue(core.verifyCheckpoint(bytes: data))

        // verifyCheckpoint on corrupt/truncated payload
        XCTAssertFalse(core.verifyCheckpoint(bytes: Data()))
        XCTAssertFalse(core.verifyCheckpoint(bytes: Data(data.prefix(10))))

        var corrupted = data
        let lastIdx = corrupted.count - 1
        corrupted[lastIdx] ^= 0xFF
        XCTAssertFalse(core.verifyCheckpoint(bytes: corrupted))
    }

    func testCheckpointRoundTripRestoresContentAndCursor() {
        let core1 = TakoCore(cols: 20, rows: 6)
        core1.feed(bytes: Data("Row 1\r\nRow 2\r\nCursorHere".utf8))

        let payload = core1.checkpoint()
        XCTAssertTrue(core1.verifyCheckpoint(bytes: payload))

        let core2 = TakoCore(cols: 80, rows: 24)
        let success = core2.restore(bytes: payload)
        XCTAssertTrue(success)

        XCTAssertEqual(core2.cols(), 20)
        XCTAssertEqual(core2.rows(), 6)
        XCTAssertEqual(core2.cursorCol(), 10)
        XCTAssertEqual(core2.cursorRow(), 2)
        XCTAssertEqual(core2.bufferText(), core1.bufferText())
    }

    func testCheckpointPreservesPendingWrap() {
        let core1 = TakoCore(cols: 20, rows: 6)
        // 20 characters fills the first row and leaves pending wrap
        core1.feed(bytes: Data(String(repeating: "x", count: 20).utf8))
        XCTAssertEqual(core1.cursorCol(), 19)
        XCTAssertEqual(core1.cursorRow(), 0)

        let payload = core1.checkpoint()

        let core2 = TakoCore(cols: 40, rows: 10)
        XCTAssertTrue(core2.restore(bytes: payload))

        // In core2, writing 'Y' should wrap to row 1, col 0 and advance to col 1
        core2.feed(bytes: Data("Y".utf8))
        XCTAssertEqual(core2.cursorCol(), 1)
        XCTAssertEqual(core2.cursorRow(), 1)
    }

    func testCheckpointPreservesInFlightParserState() {
        let core1 = TakoCore(cols: 20, rows: 6)
        // Write text followed by split CSI 2 K (erase whole line)
        core1.feed(bytes: Data("abcdefghijklmnop\u{1b}[2".utf8))

        let payload = core1.checkpoint()

        let core2 = TakoCore(cols: 20, rows: 6)
        XCTAssertTrue(core2.restore(bytes: payload))

        // Finish the CSI 2 K sequence
        core2.feed(bytes: Data("K".utf8))

        // Line should be erased (all spaces), not contain literal 'K'
        let text = core2.bufferText()
        XCTAssertFalse(text.contains("K"))
        XCTAssertFalse(text.contains("abcdefghijklmnop"))
    }

    func testMalformedRestoreReturnsFalseWithoutCrashing() {
        let core = TakoCore(cols: 20, rows: 6)
        let originalText = core.bufferText()

        XCTAssertFalse(core.restore(bytes: Data()))
        XCTAssertFalse(core.restore(bytes: Data([1, 2, 3, 4, 5])))
        XCTAssertFalse(core.restore(bytes: Data(repeating: 0xAA, count: 100)))

        // State remains intact
        XCTAssertEqual(core.bufferText(), originalText)
    }

    func testKittyGraphicsStatePreservedAcrossCheckpoint() {
        let core1 = TakoCore(cols: 20, rows: 6)
        // Position cursor at row 2, col 3 and display a 1x1 orange pixel image with id 42
        core1.feed(bytes: Data("\u{1b}[3;4H\u{1b}_Ga=T,t=d,f=32,s=1,v=1,i=42;/4AA/w==\u{1b}\\".utf8))

        let placements1 = core1.graphicsPlacements()
        XCTAssertEqual(placements1.count, 1)
        XCTAssertEqual(placements1[0].imageId, 42)
        XCTAssertEqual(placements1[0].row, 2)
        XCTAssertEqual(placements1[0].col, 3)

        let image1 = core1.graphicsImage(imageId: 42)
        XCTAssertNotNil(image1)
        XCTAssertEqual(image1?.width, 1)
        XCTAssertEqual(image1?.height, 1)
        XCTAssertEqual(image1?.pixels, Data([0xFF, 0x80, 0x00, 0xFF]))

        let payload = core1.checkpoint()
        XCTAssertTrue(core1.verifyCheckpoint(bytes: payload))

        let core2 = TakoCore(cols: 40, rows: 10)
        XCTAssertTrue(core2.restore(bytes: payload))

        let placements2 = core2.graphicsPlacements()
        XCTAssertEqual(placements2.count, 1)
        XCTAssertEqual(placements2[0].imageId, 42)
        XCTAssertEqual(placements2[0].row, 2)
        XCTAssertEqual(placements2[0].col, 3)

        let image2 = core2.graphicsImage(imageId: 42)
        XCTAssertNotNil(image2)
        XCTAssertEqual(image2?.width, 1)
        XCTAssertEqual(image2?.height, 1)
        XCTAssertEqual(image2?.pixels, Data([0xFF, 0x80, 0x00, 0xFF]))

        let meta2 = core2.graphicsImageMetadata(imageId: 42)
        XCTAssertNotNil(meta2)
        XCTAssertEqual(meta2?.width, 1)
        XCTAssertEqual(meta2?.height, 1)
        XCTAssertEqual(meta2?.generation, 1)
    }

    func testParserIntermediatesOverflowDoesNotCorruptCheckpoint() {
        let core1 = TakoCore(cols: 20, rows: 6)
        var longIntermediates = "\u{1b}["
        for _ in 0..<300 {
            longIntermediates.append(" ")
        }
        core1.feed(bytes: Data(longIntermediates.utf8))

        let payload = core1.checkpoint()
        XCTAssertTrue(core1.verifyCheckpoint(bytes: payload))

        let core2 = TakoCore(cols: 20, rows: 6)
        XCTAssertTrue(core2.restore(bytes: payload))

        // Complete the CSI sequence with 'm' (which is ignored) and print 'A'
        core2.feed(bytes: Data("mA".utf8))
        XCTAssertTrue(core2.bufferText().contains("A"))
    }
}
