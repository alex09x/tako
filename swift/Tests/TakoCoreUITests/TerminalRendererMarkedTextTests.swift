import CoreGraphics
import XCTest
@testable import TakoCoreUI

final class TerminalRendererMarkedTextTests: XCTestCase {
    private func renderer() -> TerminalRenderer {
        TerminalRenderer(metrics: .init(fontSize: 13, fontName: "Menlo"))
    }

    func testMarkedTextStartsAtTheTerminalCursorWhenItFits() {
        let layout = renderer().markedTextLayout(
            "тест",
            cursorCol: 2,
            cols: 10,
            availableRows: 4
        )

        XCTAssertEqual(layout.lines, [.init(row: 0, cellRange: 2..<6)])
        XCTAssertEqual(layout.glyphs.map(\.text).joined(), "тест")
        XCTAssertTrue(layout.glyphs.allSatisfy {
            $0.row == 0 && $0.col >= 2 && $0.col < 10
        })
    }

    func testLongMarkedTextWrapsToTheNextGridRowWithoutHidingItsPrefix() {
        let layout = renderer().markedTextLayout(
            "abcdefgh",
            cursorCol: 4,
            cols: 8,
            availableRows: 4
        )

        XCTAssertEqual(layout.lines, [
            .init(row: 0, cellRange: 4..<8),
            .init(row: 1, cellRange: 0..<4),
        ])
        XCTAssertEqual(layout.glyphs.map(\.text).joined(), "abcdefgh")
        XCTAssertEqual(layout.glyphs.map(\.row), [0, 0, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(layout.glyphs.map(\.col), [4, 5, 6, 7, 0, 1, 2, 3])
    }

    func testMarkedTextKeepsTheActiveTailVisibleAfterFillingAvailableRows() {
        let layout = renderer().markedTextLayout(
            "abcdefghijklmnop",
            cursorCol: 4,
            cols: 8,
            availableRows: 2
        )

        XCTAssertEqual(layout.lines, [
            .init(row: 0, cellRange: 0..<8),
            .init(row: 1, cellRange: 0..<4),
        ])
        XCTAssertEqual(layout.glyphs.map(\.text).joined(), "efghijklmnop")
    }

    func testMarkedTextLayoutIsEmptyForAnEmptyGrid() {
        let layout = renderer().markedTextLayout(
            "text",
            cursorCol: 0,
            cols: 0,
            availableRows: 4
        )

        XCTAssertTrue(layout.lines.isEmpty)
        XCTAssertTrue(layout.glyphs.isEmpty)
    }
}
