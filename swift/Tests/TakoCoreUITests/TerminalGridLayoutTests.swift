import Foundation
import XCTest
@testable import TakoCoreUI

/// Where the grid sits in a view: window-padding-x, window-padding-y and
/// window-padding-balance.
final class TerminalGridLayoutTests: XCTestCase {
    private let cell = CGSize(width: 10, height: 20)

    func testPaddingParsesOneValueOrAPair() {
        let theme = TerminalTheme.parse(config: "window-padding-x = 3,7\nwindow-padding-y = 5\n")
        XCTAssertEqual(theme.padding, TerminalPadding(left: 3, right: 7, top: 5, bottom: 5))

        let invalid = TerminalTheme.parse(config: "window-padding-x = -1\nwindow-padding-y = 1,2,3\n")
        XCTAssertEqual(invalid.padding, TerminalTheme.takoDefault.padding, "invalid values keep the default")
        XCTAssertEqual(TerminalTheme.takoDefault.padding, TerminalPadding(uniform: 10))
    }

    func testTheGridFitsWholeCellsInsideThePadding() {
        let layout = TerminalGridLayout(
            viewSize: CGSize(width: 125, height: 90), cellSize: cell,
            padding: TerminalPadding(left: 3, right: 7, top: 5, bottom: 5), balance: false
        )
        XCTAssertEqual([layout.cols, layout.rows], [11, 4])
        XCTAssertEqual([layout.left, layout.top], [3, 5])
        XCTAssertEqual(layout.right(in: CGSize(width: 125, height: 90)), 12)
        XCTAssertEqual(layout.bottom(in: CGSize(width: 125, height: 90)), 5)
    }

    func testBalanceCentresTheGridInTheSpareSpace() {
        let layout = TerminalGridLayout(
            viewSize: CGSize(width: 125, height: 90), cellSize: cell,
            padding: TerminalPadding(left: 3, right: 7, top: 5, bottom: 5), balance: true
        )
        // 5pt spare across, 0 down: half of it goes to the left.
        XCTAssertEqual([layout.left, layout.top], [5, 5])
    }

    /// A window sized as cells times the cell size plus the padding must fit
    /// exactly that many cells, whatever the multiplication rounded to.
    func testASizeMadeFromCellsFitsThatManyCells() {
        let cell = CGSize(width: 8.4, height: 17.3)
        let padding = TerminalPadding(uniform: 10)
        for cols in [80, 200, 333] {
            let size = CGSize(width: cell.width * CGFloat(cols) + 20, height: cell.height * 60 + 20)
            let layout = TerminalGridLayout(viewSize: size, cellSize: cell, padding: padding, balance: false)
            XCTAssertEqual([layout.cols, layout.rows], [cols, 60])
        }
    }

    func testAPointMapsToTheCellUnderItAndThePaddingToTheNearestEdgeCell() {
        let layout = TerminalGridLayout(
            viewSize: CGSize(width: 125, height: 90), cellSize: cell,
            padding: TerminalPadding(left: 3, right: 7, top: 5, bottom: 5), balance: false
        )
        XCTAssertEqual(layout.cell(atTopLeftPoint: CGPoint(x: 3, y: 5), cols: 11, rows: 4).col, 0)
        XCTAssertEqual(layout.cell(atTopLeftPoint: CGPoint(x: 13, y: 25), cols: 11, rows: 4).col, 1)
        XCTAssertEqual(layout.cell(atTopLeftPoint: CGPoint(x: 13, y: 25), cols: 11, rows: 4).row, 1)
        XCTAssertEqual(layout.cell(atTopLeftPoint: CGPoint(x: 0, y: 0), cols: 11, rows: 4).col, 0)
        XCTAssertEqual(layout.cell(atTopLeftPoint: CGPoint(x: 124, y: 89), cols: 11, rows: 4).col, 10)
        XCTAssertEqual(layout.cell(atTopLeftPoint: CGPoint(x: 124, y: 89), cols: 11, rows: 4).row, 3)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class TakoTerminalNSViewPaddingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TakoTerminalNSView.isMetalDisabledForTesting = true
    }

    private func view(_ config: String) -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.theme = TerminalTheme.parse(config: config)
        view.setFrameSize(NSSize(width: 400, height: 200))
        return view
    }

    /// cellOrigin and cellAt are inverses with the padding in place: the
    /// middle of the cell cellOrigin names is the cell cellAt reports.
    func testCellOriginAndCellAtAgreeWithThePadding() {
        let view = view("window-padding-x = 12\nwindow-padding-y = 9\n")
        let origin = view.cellOrigin(row: 0, col: 0)
        XCTAssertEqual(origin.x, 12)
        XCTAssertEqual(origin.y, view.bounds.height - 9 - view.cellHeight, accuracy: 0.001)
        for (row, col) in [(0, 0), (1, 3), (view.rows - 1, view.cols - 1)] {
            let point = view.cellOrigin(row: row, col: col)
            let hit = view.cellAt(NSPoint(x: point.x + view.cellWidth / 2, y: point.y + view.cellHeight / 2))
            XCTAssertEqual(hit.row, row)
            XCTAssertEqual(hit.col, col)
        }
    }

    /// The input method's candidate window follows the grid, padding and all.
    func testTheInputMethodRectIsOffsetByTheGridOrigin() {
        let rect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 2, cursorRow: 1, cols: 10, rows: 5,
            cellSize: CGSize(width: 8, height: 16), viewHeight: 100,
            range: NSRange(location: 0, length: 1),
            gridOrigin: CGPoint(x: 12, y: 9)
        )
        XCTAssertEqual(rect.minX, 12 + 16)
        XCTAssertEqual(rect.minY, 100 - 9 - 32)
    }
}
#endif
