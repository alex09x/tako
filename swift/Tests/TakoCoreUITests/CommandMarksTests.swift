import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class CommandMarksTests: XCTestCase {
    func testCommandMarksGutterAndScrollbarTracksStatus() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(view.commandMarksEnabled, "command-marks should be enabled by default")

        // Feed three commands: success (0), failure (1), running (no D yet)
        let seq1 = Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}true\r\n\u{1b}]133;D;0\u{07}".utf8)
        let seq2 = Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}false\r\n\u{1b}]133;D;1\u{07}".utf8)
        let seq3 = Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}sleep 10\r\n".utf8)

        view.feed(data: seq1)
        view.feed(data: seq2)
        view.feed(data: seq3)

        let marks = view.core.commandMarks()
        XCTAssertEqual(marks.count, 3)

        // Mark 0: success (status 1, exit_code 0)
        XCTAssertEqual(marks[0].status, 1)
        XCTAssertEqual(marks[0].exitCode, 0)

        // Mark 1: error (status 2, exit_code 1)
        XCTAssertEqual(marks[1].status, 2)
        XCTAssertEqual(marks[1].exitCode, 1)

        // Mark 2: running (status 0, exit_code nil)
        XCTAssertEqual(marks[2].status, 0)
        XCTAssertNil(marks[2].exitCode)

        // Trigger scroller and gutter marks update
        view.updateScroller()

        // Toggle command marks off
        view.commandMarksEnabled = false
        view.updateScroller()

        // Toggle back on
        view.commandMarksEnabled = true
        view.updateScroller()

        // Add search hit marks
        view.searchHitRetainedRows = [0, 1]
        XCTAssertEqual(view.searchHitRetainedRows, [0, 1])

        // Clear search hit marks
        view.searchHitRetainedRows = []
        XCTAssertTrue(view.searchHitRetainedRows.isEmpty)
    }

    func testCommandMarksEmptyOnAlternateScreen() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let seq = Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}echo test\r\n\u{1b}]133;D;0\u{07}".utf8)
        view.feed(data: seq)

        XCTAssertEqual(view.core.commandMarks().count, 1)

        // Enter alternate screen
        view.feed(data: Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(view.core.modes().alternateScreen)
        XCTAssertTrue(view.core.commandMarks().isEmpty, "command marks must be empty on alternate screen")

        // Exit alternate screen
        view.feed(data: Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(view.core.modes().alternateScreen)
        XCTAssertEqual(view.core.commandMarks().count, 1, "command marks restore when returning to primary screen")
    }

    func testStatusOnlyCommandEventUpdatesMarks() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.commandMarksEnabled = true

        // 1. Start command (blue/running mark)
        view.feed(data: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}".utf8))
        let marks1 = view.core.commandMarks()
        XCTAssertEqual(marks1.count, 1)
        XCTAssertEqual(marks1[0].status, 0, "status should be running")

        // 2. Feed status-only exit code (133;D;0) with NO printable cells / damage
        view.feed(data: Data("\u{1b}]133;D;0\u{07}".utf8))
        let marks2 = view.core.commandMarks()
        XCTAssertEqual(marks2.count, 1)
        XCTAssertEqual(marks2[0].status, 1, "status should update to success")
    }

    func testAbandonedCommandUpdatesMarkToError() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.commandMarksEnabled = true

        // 1. Start a command (blue/running mark)
        view.feed(data: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}".utf8))
        let marks1 = view.core.commandMarks()
        XCTAssertEqual(marks1.count, 1)
        XCTAssertEqual(marks1[0].status, 0, "status should be running")

        // 2. Feed OSC 133;A with NO printable cells / damage (e.g. Ctrl-C gives a new prompt)
        view.feed(data: Data("\u{1b}]133;A\u{07}".utf8))
        let marks2 = view.core.commandMarks()
        XCTAssertEqual(marks2.count, 1)
        XCTAssertEqual(marks2[0].status, 2, "status should update to error/abandoned")
    }

    func testCheckpointRestoreRefreshesMarks() throws {
        let view1 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view1.commandMarksEnabled = true
        view1.feed(data: Data("\u{1b}]133;A\u{07}$ \u{1b}]133;C\u{07}echo test\r\n\u{1b}]133;D;0\u{07}".utf8))
        XCTAssertEqual(view1.core.commandMarks().count, 1)

        let blob = try view1.exportCheckpoint()

        // Create a fresh view with no marks
        let view2 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view2.commandMarksEnabled = true
        XCTAssertEqual(view2.core.commandMarks().count, 0)

        // Restore checkpoint into view2
        try view2.importCheckpoint(blob)

        // Marks must be immediately present and scroller updated without requiring additional feed
        let marks = view2.core.commandMarks()
        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].status, 1)
    }
}
#endif


