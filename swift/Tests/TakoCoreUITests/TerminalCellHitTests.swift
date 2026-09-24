import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Where a click lands.
///
/// The renderer draws row `r` at `r * cellHeight` from the top of the layer,
/// and the layer covers the whole view. So the row under a point is decided
/// by the distance from the top, and nothing else -- no padding, no counting
/// up from the bottom. When the hit test disagrees with that, selection picks
/// the wrong line and the only way to select what you want is to aim at the
/// row below it.
@MainActor
final class TerminalCellHitTests: XCTestCase {
    private func makeView(height: CGFloat = 300) -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: height))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The middle of every drawn row must hit that row.
    func testEveryRowIsHitAtItsOwnCentre() {
        let view = makeView()
        let h = view.cellHeight
        XCTAssertGreaterThan(h, 0)

        for row in 0..<view.rows {
            // The rect the renderer actually paints, in view coordinates:
            // unflipped, so row 0 is the topmost band below the top padding.
            let centreY = view.bounds.height - view.gridLayout.top - (CGFloat(row) + 0.5) * h
            guard centreY > 0 else { continue }
            let hit = view.cellAt(NSPoint(x: 20, y: centreY))
            XCTAssertEqual(
                hit.row, row,
                "a click in the middle of row \(row) landed on row \(hit.row)")
        }
    }

    /// The top row is where the top of the view is.
    func testTheTopOfTheViewIsTheFirstRow() {
        let view = makeView()
        let hit = view.cellAt(NSPoint(x: 20, y: view.bounds.height - view.cellHeight / 2))
        XCTAssertEqual(hit.row, 0)
    }

    /// Columns follow the same rule from the left padding.
    func testColumnsFollowTheDrawnGrid() {
        let view = makeView()
        let w = view.cellWidth
        for col in [0, 1, 5, view.cols - 1] where col >= 0 {
            let centreX = view.gridLayout.left + (CGFloat(col) + 0.5) * w
            let hit = view.cellAt(NSPoint(x: centreX, y: view.bounds.height - w))
            XCTAssertEqual(hit.col, col, "a click in the middle of column \(col) landed on \(hit.col)")
        }
    }

    /// `cellOrigin` is the inverse: what it returns for a cell must hit that
    /// cell again. A mismatch here is what puts a dictation caret or a marked
    /// text run on the wrong line.
    func testCellOriginRoundTripsThroughCellAt() {
        let view = makeView()
        for row in [0, 1, view.rows / 2, view.rows - 1] {
            let origin = view.cellOrigin(row: row, col: 3)
            // cellOrigin gives the cell's lower-left corner, so aim just above
            // it to land inside the same cell.
            let hit = view.cellAt(NSPoint(x: origin.x + 1, y: origin.y + view.cellHeight / 2))
            XCTAssertEqual(hit.row, row, "cellOrigin(row: \(row)) does not map back to row \(row)")
            XCTAssertEqual(hit.col, 3)
        }
    }
}
#endif
