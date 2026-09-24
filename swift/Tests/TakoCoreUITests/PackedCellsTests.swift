import XCTest
import Foundation
@testable import TakoCoreUI

final class PackedCellsTests: XCTestCase {
    private struct CellSpec {
        let ch: UInt32
        let fgR: UInt8
        let fgG: UInt8
        let fgB: UInt8
        let bgR: UInt8
        let bgG: UInt8
        let bgB: UInt8
        let underlineStyle: UInt8
        let ulR: UInt8
        let ulG: UInt8
        let ulB: UInt8
        let bits: UInt16
    }

    private func packedCell(_ spec: CellSpec) -> [UInt8] {
        [
            UInt8(spec.ch & 0xFF),
            UInt8((spec.ch >> 8) & 0xFF),
            UInt8((spec.ch >> 16) & 0xFF),
            UInt8((spec.ch >> 24) & 0xFF),
            spec.fgR, spec.fgG, spec.fgB,
            spec.bgR, spec.bgG, spec.bgB,
            UInt8(spec.bits & 0xFF),
            UInt8(spec.bits >> 8),
            spec.underlineStyle,
            spec.ulR, spec.ulG, spec.ulB,
        ]
    }

    private func makeFrame(cells: [[CellSpec]], cols: Int, rows: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(cols * rows * TerminalCell.byteSize)
        for row in cells {
            for spec in row {
                bytes.append(contentsOf: packedCell(spec))
            }
        }
        return Data(bytes)
    }

    func testSequentialTraversalAndRandomAccess() {
        let cells = [
            [
                CellSpec(ch: 65, fgR: 1, fgG: 2, fgB: 3, bgR: 4, bgG: 5, bgB: 6, underlineStyle: 11, ulR: 21, ulG: 22, ulB: 23, bits: 0),
                CellSpec(ch: 66, fgR: 7, fgG: 8, fgB: 9, bgR: 10, bgG: 11, bgB: 12, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 1),
            ],
            [
                CellSpec(ch: 67, fgR: 13, fgG: 14, fgB: 15, bgR: 16, bgG: 17, bgB: 18, underlineStyle: 9, ulR: 19, ulG: 20, ulB: 21, bits: 2),
                CellSpec(ch: 68, fgR: 22, fgG: 23, fgB: 24, bgR: 25, bgG: 26, bgB: 27, underlineStyle: 3, ulR: 28, ulG: 29, ulB: 30, bits: 3),
            ],
        ]
        let frame = TerminalFrame(packed: makeFrame(cells: cells, cols: 2, rows: 2), cols: 2, rows: 2)

        var seen = [(Int, Int, UInt32)]()
        frame.forEachCell { row, col, cell in
            seen.append((row, col, cell.ch))
        }
        XCTAssertEqual(seen.count, 4)
        XCTAssertEqual(seen.map(\.0), [0, 0, 1, 1])
        XCTAssertEqual(seen.map(\.1), [0, 1, 0, 1])
        XCTAssertEqual(seen.map(\.2), [65, 66, 67, 68])

        XCTAssertEqual(frame.cell(atRow: 1, column: 0)?.ch, 67)
        XCTAssertEqual(frame.cell(at: 2)?.ch, 67)
        XCTAssertNil(frame.cell(atRow: 2, column: 0))
        XCTAssertNil(frame.cell(at: 4))
    }

    func testColorsAndUnicodeScalarsAreParsed() {
        let emoji = UInt32(0x1F60A)
        let invalid = UInt32(0x110000)
        let cells = [
            [
                CellSpec(ch: emoji, fgR: 255, fgG: 254, fgB: 253, bgR: 1, bgG: 2, bgB: 3, underlineStyle: 0xAA, ulR: 8, ulG: 9, ulB: 10, bits: 0),
                CellSpec(ch: invalid, fgR: 4, fgG: 5, fgB: 6, bgR: 7, bgG: 8, bgB: 9, underlineStyle: 0xBB, ulR: 11, ulG: 12, ulB: 13, bits: 0),
            ],
        ]
        let frame = TerminalFrame(packed: makeFrame(cells: cells, cols: 2, rows: 1), cols: 2, rows: 1)
        let first = frame.cell(atRow: 0, column: 0)
        let second = frame.cell(atRow: 0, column: 1)

        XCTAssertEqual(first?.fgR, 255)
        XCTAssertEqual(first?.fgG, 254)
        XCTAssertEqual(first?.fgB, 253)
        XCTAssertEqual(first?.bgR, 1)
        XCTAssertEqual(first?.bgG, 2)
        XCTAssertEqual(first?.bgB, 3)
        XCTAssertEqual(first?.underlineStyle, 0xAA)
        XCTAssertEqual(first?.unicodeScalar, UnicodeScalar(emoji))
        XCTAssertNil(second?.unicodeScalar)
    }

    func testValidationAndShortInput() {
        let complete = [
            [CellSpec(ch: 1, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0)],
        ]
        let full = makeFrame(cells: complete, cols: 1, rows: 1)
        let short = full.prefix(TerminalCell.byteSize / 2)
        let frame = TerminalFrame(packed: Data(short), cols: 1, rows: 1)

        XCTAssertEqual(frame.validate(), .truncatedPayload)
        var count = 0
        frame.forEachCell { _, _, _ in
            count += 1
        }
        XCTAssertEqual(count, 0)
        XCTAssertNil(frame.cell(atRow: 0, column: 0))
    }

    func testRowAllocationPathStillWorksForEmptyOrMalformedData() {
        let malformed = TerminalFrame(packed: Data([0x00, 0x01]), cols: -1, rows: 2)
        XCTAssertEqual(malformed.validate(), .invalidDimensions)
        XCTAssertTrue(malformed.row(0).isEmpty)
        XCTAssertNil(malformed.cell(atRow: 0, column: 0))
    }

    func testForEachCellCanIterateAClippedViewport() {
        let cells = [
            [
                CellSpec(ch: 65, fgR: 1, fgG: 2, fgB: 3, bgR: 4, bgG: 5, bgB: 6, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
                CellSpec(ch: 66, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
                CellSpec(ch: 67, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
            ],
            [
                CellSpec(ch: 68, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
                CellSpec(ch: 69, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
                CellSpec(ch: 70, fgR: 0, fgG: 0, fgB: 0, bgR: 0, bgG: 0, bgB: 0, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
            ],
        ]
        let frame = TerminalFrame(packed: makeFrame(cells: cells, cols: 3, rows: 2), cols: 3, rows: 2)
        var seen = [(Int, Int, UInt32)]()

        frame.forEachCell(inRows: 0..<1, inColumns: 1..<3) { row, col, cell in
            seen.append((row, col, cell.ch))
        }
        XCTAssertEqual(seen.map { $0.0 }, [0, 0])
        XCTAssertEqual(seen.map { $0.1 }, [1, 2])
        XCTAssertEqual(seen.map { $0.2 }, [66, 67])

        seen.removeAll()
        frame.forEachCell(inRows: -1..<10, inColumns: -2..<2) { row, col, cell in
            seen.append((row, col, cell.ch))
        }
        XCTAssertEqual(seen.map { $0.0 }, [0, 0, 1, 1])
        XCTAssertEqual(seen.map { $0.1 }, [0, 1, 0, 1])
        XCTAssertEqual(seen.map { $0.2 }, [65, 66, 68, 69])
    }

    func testRowMatchesExactComparison() throws {
        let cells = [
            [
                CellSpec(ch: 65, fgR: 1, fgG: 2, fgB: 3, bgR: 4, bgG: 5, bgB: 6, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 0),
                CellSpec(ch: 66, fgR: 7, fgG: 8, fgB: 9, bgR: 10, bgG: 11, bgB: 12, underlineStyle: 0, ulR: 0, ulG: 0, ulB: 0, bits: 1),
            ],
            [
                CellSpec(ch: 67, fgR: 13, fgG: 14, fgB: 15, bgR: 16, bgG: 17, bgB: 18, underlineStyle: 9, ulR: 19, ulG: 20, ulB: 21, bits: 2),
                CellSpec(ch: 68, fgR: 22, fgG: 23, fgB: 24, bgR: 25, bgG: 26, bgB: 27, underlineStyle: 3, ulR: 28, ulG: 29, ulB: 30, bits: 3),
            ],
        ]
        let fullData = makeFrame(cells: cells, cols: 2, rows: 2)
        let frame = TerminalFrame(packed: fullData, cols: 2, rows: 2)

        // 1. Matches full viewport data for row 0 and row 1
        XCTAssertTrue(frame.rowMatches(fullData, row: 0))
        XCTAssertTrue(frame.rowMatches(fullData, row: 1))

        // 2. Matches per-row cached packed data (count == bytesPerRow)
        let row0Data = try XCTUnwrap(frame.rowData(for: 0))
        let row1Data = try XCTUnwrap(frame.rowData(for: 1))
        XCTAssertTrue(frame.rowMatches(row0Data, row: 0))
        XCTAssertTrue(frame.rowMatches(row1Data, row: 1))
        XCTAssertFalse(frame.rowMatches(row0Data, row: 1))
        XCTAssertFalse(frame.rowMatches(row1Data, row: 0))

        // 3. Mutated row does not match
        var mutatedData = fullData
        mutatedData[0] ^= 0xFF
        XCTAssertFalse(frame.rowMatches(mutatedData, row: 0))
        XCTAssertTrue(frame.rowMatches(mutatedData, row: 1))

        // 4. Out of bounds row / malformed data
        XCTAssertFalse(frame.rowMatches(fullData, row: -1))
        XCTAssertFalse(frame.rowMatches(fullData, row: 2))
        XCTAssertFalse(frame.rowMatches(Data(), row: 0))
        XCTAssertFalse(frame.rowMatches(fullData.prefix(5), row: 0))
    }

    func testGraphemeClustersArriveBesideThePackedCells() throws {
        let core = TakoCore(cols: 10, rows: 2)
        // q + combining acute has no precomposed form; thumbs up + skin tone
        // is one two-column cluster.
        core.feed(bytes: Data("q\u{0301}x\u{1F44D}\u{1F3FD}".utf8))
        let rendered = core.renderFrame()
        let frame = TerminalFrame(packed: rendered.packedCells, cols: 10, rows: 2)
        XCTAssertEqual(frame.validate(), .valid)

        let mark = try XCTUnwrap(frame.cell(atRow: 0, column: 0))
        XCTAssertEqual(mark.ch, UInt32(("q" as UnicodeScalar).value))
        XCTAssertTrue(mark.hasGrapheme)
        XCTAssertFalse(try XCTUnwrap(frame.cell(atRow: 0, column: 1)).hasGrapheme)
        let emoji = try XCTUnwrap(frame.cell(atRow: 0, column: 2))
        XCTAssertTrue(emoji.hasGrapheme)

        XCTAssertEqual(rendered.graphemes.map(\.text), ["q\u{0301}", "\u{1F44D}\u{1F3FD}"])
        XCTAssertEqual(rendered.graphemes.map(\.col), [0, 2])
        XCTAssertEqual(core.viewportGraphemes(), rendered.graphemes)

        let cell = try XCTUnwrap(core.getCell(row: 0, col: 0))
        XCTAssertEqual(cell.grapheme, "q\u{0301}")
        XCTAssertTrue(TerminalCell(cell).hasGrapheme)
        XCTAssertNil(try XCTUnwrap(core.getCell(row: 0, col: 1)).grapheme)
    }

    func testLegacyGraphemeWidthSumsCodepointWidths() {
        let core = TakoCore(cols: 10, rows: 2)
        core.setGraphemeWidthMethod(method: .legacy)
        core.feed(bytes: Data("\u{1F44D}\u{1F3FD}".utf8))
        XCTAssertEqual(core.cursorCol(), 4)
        XCTAssertEqual(core.getPlainText(startRow: 0, maxRows: 1), "\u{1F44D}\u{1F3FD}")
    }
}
