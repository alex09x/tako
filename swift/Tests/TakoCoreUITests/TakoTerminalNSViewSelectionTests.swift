import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Double-click selection and the native Copy that publishes it.
///
/// The engine's own word selection is covered in Rust. What is covered here is
/// the part between a thumb and that engine: a click landing on the right cell,
/// the click count choosing word rather than character selection, and Cmd-C
/// publishing exactly what was selected. A consumer's fail-before on the
/// previous terminal showed a URL selecting nothing at all, which no
/// engine-level test would have caught.
@MainActor
final class TakoTerminalNSViewSelectionTests: XCTestCase {
    private let line = "ordinaryword /usr/local/bin/some-cool_file.txt https://example.com/a/b?x=1&y=2#frag"

    private func makeView() -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
        view.layoutSubtreeIfNeeded()
        view.feed(data: Data((line + "\r\n").utf8))
        return view
    }

    /// The centre of the cell at `col` on the top row, in view coordinates.
    ///
    /// Mirrors the view's own point-to-cell mapping rather than guessing at a
    /// pixel: a test that clicks the wrong cell fails for a reason that has
    /// nothing to do with selection.
    private func point(forColumn col: Int, in view: TakoTerminalNSView) -> NSPoint {
        let origin = view.cellOrigin(row: 0, col: col)
        return NSPoint(x: origin.x + max(view.cellWidth, 1) / 2,
                       y: origin.y + max(view.cellHeight, 1) / 2)
    }

    private func doubleClick(column: Int, in view: TakoTerminalNSView) {
        let location = point(forColumn: column, in: view)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ) else {
            XCTFail("could not synthesize a double click")
            return
        }
        view.mouseDown(with: event)
    }

    func testDoubleClickSelectsAWord() {
        let view = makeView()
        doubleClick(column: 3, in: view)
        XCTAssertEqual(view.core.selectedText(), "ordinaryword")
    }

    func testDoubleClickSelectsAWholePath() {
        let view = makeView()
        doubleClick(column: 20, in: view)
        XCTAssertEqual(view.core.selectedText(), "/usr/local/bin/some-cool_file.txt")
    }

    /// The case a consumer found selecting nothing on the previous terminal.
    /// A URL must come back whole, scheme separator, query and fragment
    /// included, rather than stopping at the first punctuation run.
    func testDoubleClickSelectsAWholeURL() {
        let view = makeView()
        doubleClick(column: 60, in: view)
        XCTAssertEqual(view.core.selectedText(), "https://example.com/a/b?x=1&y=2#frag")
    }

    func testCopyPublishesExactlyTheSelectedURL() {
        let view = makeView()
        var published: [String] = []
        view.copyStringConsumer = { published.append($0) }

        doubleClick(column: 60, in: view)
        view.copy(nil)

        XCTAssertEqual(published, ["https://example.com/a/b?x=1&y=2#frag"])
        // Copying is not a reason to lose the selection, and a URL is not a
        // reason to go anywhere: the view has no opening behaviour, and this
        // pins that it stays that way.
        XCTAssertEqual(view.core.selectedText(), "https://example.com/a/b?x=1&y=2#frag")
    }

    func testCopyWithNoSelectionPublishesNothing() {
        let view = makeView()
        var published: [String] = []
        view.copyStringConsumer = { published.append($0) }

        view.copy(nil)

        XCTAssertTrue(published.isEmpty, "copy published \(published) with nothing selected")
    }

    func testShiftLeftForcesLinearNativeSelectionThroughModifierChanges() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let baseline = delegate.inputDataReceived.count
        let start = point(forColumn: 0, in: view)
        let end = point(forColumn: 11, in: view)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [.shift, .option], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [.option], timestamp: 3, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!

        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)

        XCTAssertEqual(delegate.inputDataReceived.count, baseline, "Shift selection must not report press, drag, or release")
        XCTAssertEqual(view.core.selectedText(), "ordinaryword", "Shift wins over Option and keeps a linear selection")
    }

    func testOptionLeftWithoutShiftRetainsRectangularSelection() {
        let view = makeView()
        let start = point(forColumn: 0, in: view)
        let end = point(forColumn: 4, in: view)
        view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [.option], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        view.mouseDragged(with: NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [.option], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertEqual(view.core.selectionRange()?.mode, .rectangular)
    }

    func testUnmodifiedMousePressDragReleaseRemainsProgramOwned() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        let baseline = delegate.inputDataReceived.count
        let start = point(forColumn: 0, in: view)
        let end = point(forColumn: 11, in: view)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [], timestamp: 3, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let downCell = view.cellAt(view.convert(start, from: nil))
        let dragCell = view.cellAt(view.convert(end, from: nil))
        let expected = view.mouseReportBytes(button: .left, action: .press, cell: downCell, event: down)
            + view.mouseReportBytes(button: .left, action: .motion, cell: dragCell, event: drag)
            + view.mouseReportBytes(button: .left, action: .release, cell: dragCell, event: up)

        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)

        XCTAssertEqual(delegate.inputDataReceived.dropFirst(baseline), expected)
        XCTAssertFalse(view.core.hasSelection(), "unmodified program-owned mouse input must not start native selection")
    }
}
#endif
