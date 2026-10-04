import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class StickyCommandHeaderTests: XCTestCase {
    func testStickyCommandHeaderPinnedWhileScrolledIntoOutput() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(view.stickyCommandHeaderEnabled, "sticky-command-header should be enabled by default")

        // Feed command with 40 lines of output
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git log\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "commit \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        // While sitting at bottom, prompt at row 0 has scrolled off the top
        let header = view.currentStickyCommandHeader()
        XCTAssertNotNil(header, "sticky command header must pin when prompt scrolled off top")
        XCTAssertEqual(header?.command, "git log")
        XCTAssertEqual(header?.promptRetainedRow, 0)
        XCTAssertEqual(header?.status, 1, "status should be success")
        XCTAssertEqual(header?.exitCode, 0)

        view.updateScroller()
        XCTAssertFalse(view.stickyHeaderLayer.isHidden, "stickyHeaderLayer must be visible")
        XCTAssertEqual(view.activeStickyCommandHeader, header)
    }

    func testClickStickyHeaderJumpsToPrompt() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cat long_file.txt\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "line \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        let header = view.currentStickyCommandHeader()
        XCTAssertNotNil(header)

        // Click / jump to prompt
        view.jumpToPrompt(retainedRow: header!.promptRetainedRow)

        // Prompt is now at top of visible screen, so header must unpin
        XCTAssertNil(view.currentStickyCommandHeader(), "header must unpin when prompt is visible on screen")
        XCTAssertTrue(view.stickyHeaderLayer.isHidden, "stickyHeaderLayer must be hidden")
    }

    func testStickyCommandHeaderNoneWhenPromptVisible() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Short command (2 lines of output) where prompt remains visible on screen
        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo hi\r\n\u{1b}]133;C\u{07}hi\r\n\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        view.updateScroller()
        XCTAssertNil(view.currentStickyCommandHeader(), "header must not appear when prompt is visible on screen")
        XCTAssertTrue(view.stickyHeaderLayer.isHidden)
    }

    func testStickyCommandHeaderDisabledSuppressesLayer() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}test-cmd\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "data \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        XCTAssertNotNil(view.currentStickyCommandHeader())

        // Disable feature
        view.stickyCommandHeaderEnabled = false
        XCTAssertNil(view.currentStickyCommandHeader())
        XCTAssertTrue(view.stickyHeaderLayer.isHidden)

        // Re-enable feature
        view.stickyCommandHeaderEnabled = true
        XCTAssertNotNil(view.currentStickyCommandHeader())
        XCTAssertFalse(view.stickyHeaderLayer.isHidden)
    }

    func testStickyCommandHeaderSuppressedOnAlternateScreen() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}run-editor\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "row \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        XCTAssertNotNil(view.currentStickyCommandHeader())

        // Enter alternate screen
        view.feed(data: Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(view.core.modes().alternateScreen)
        XCTAssertNil(view.currentStickyCommandHeader(), "header must be nil on alternate screen")
        XCTAssertTrue(view.stickyHeaderLayer.isHidden)

        // Exit alternate screen
        view.feed(data: Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(view.core.modes().alternateScreen)
        XCTAssertNotNil(view.currentStickyCommandHeader(), "header restores on primary screen")
        XCTAssertFalse(view.stickyHeaderLayer.isHidden)
    }

    func testStickyCommandHeaderNeverAppearsWithoutOSC133() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // 50 lines of unmarked text
        var input = ""
        for i in 1...50 {
            input += "unmarked line \(i)\r\n"
        }
        view.feed(data: Data(input.utf8))

        view.updateScroller()
        XCTAssertNil(view.currentStickyCommandHeader(), "must never appear without OSC 133 boundaries")
        XCTAssertTrue(view.stickyHeaderLayer.isHidden)
    }

    func testStickyCommandHeaderTracksRunningCommand() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Start running command (no 133;D)
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cargo test --all\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "running test \(i)...\r\n"
        }
        view.feed(data: Data(input.utf8))

        let runningHeader = view.currentStickyCommandHeader()
        XCTAssertNotNil(runningHeader)
        XCTAssertEqual(runningHeader?.command, "cargo test --all")
        XCTAssertEqual(runningHeader?.status, 0, "status should be running (0)")
        XCTAssertNil(runningHeader?.exitCode)

        // Complete command with exit code 2
        view.feed(data: Data("\u{1b}]133;D;2\u{07}".utf8))
        let completedHeader = view.currentStickyCommandHeader()
        XCTAssertEqual(completedHeader?.status, 2, "status should be error (2)")
        XCTAssertEqual(completedHeader?.exitCode, 2)
    }

    func testMouseDownOnStickyHeaderTriggersJump() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}find . -name \"*.swift\"\r\n\u{1b}]133;C\u{07}"
        for i in 1...45 {
            input += "file_\(i).swift\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        view.updateScroller()
        XCTAssertFalse(view.stickyHeaderLayer.isHidden)

        // Synthesize mouse down event in center of sticky header layer
        let headerMid = CGPoint(x: view.stickyHeaderLayer.frame.midX, y: view.stickyHeaderLayer.frame.midY)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: headerMid,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1.0
        )!

        view.mouseDown(with: event)

        // Viewport should have jumped to prompt, and header is now unpinned
        XCTAssertNil(view.currentStickyCommandHeader())
        XCTAssertTrue(view.stickyHeaderLayer.isHidden)
    }

    func testStickyCommandHeaderSuppressedOnUnownedShellHookText() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Command 1: prompt at row 0, 20 lines of output, completed with 133;D
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git log\r\n\u{1b}]133;C\u{07}"
        for i in 1...20 {
            input += "commit \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"

        // Shell hook prints unowned lines (not wrapped in 133;C/D)
        for i in 1...50 {
            input += "hook line \(i)\r\n"
        }

        // Prompt 2 starts
        input += "\u{1b}]133;A\u{07}$ "
        view.feed(data: Data(input.utf8))

        // While sitting at bottom, viewport spans unowned hook lines and prompt 2.
        // It must NOT show the previous command header.
        XCTAssertNil(view.currentStickyCommandHeader(), "unowned shell hook text after 133;D must not show previous command header")

        // Scroll back up into git log's output:
        view.scrollViewportUp(lines: 40)
        let header = view.currentStickyCommandHeader()
        XCTAssertNotNil(header, "should pin git log when scrolled into its output")
        XCTAssertEqual(header?.command, "git log")
    }

    func testStickyCommandHeaderPreservedWhenPromptEvicted() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.core.setScrollbackLimit(lines: 10)

        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cargo test\r\n\u{1b}]133;C\u{07}"
        for i in 1...60 {
            input += "test line \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        // Prompt line (line 0) was evicted because 60 lines exceeded scrollback capacity
        XCTAssertGreaterThan(view.core.firstRetainedLine(), 0, "prompt line must have been evicted")
        XCTAssertTrue(view.core.commandMarks().isEmpty, "commandMarks must omit evicted prompt")

        // Scroll up into retained scrollback
        view.scrollViewportUp(lines: 8)
        let header = view.currentStickyCommandHeader()
        XCTAssertNotNil(header, "header must be preserved even when prompt is evicted")
        XCTAssertEqual(header?.command, "cargo test")
        XCTAssertEqual(header?.promptRetainedRow, 0, "evicted prompt falls back to row 0")

        // Jump to prompt
        view.jumpToPrompt(retainedRow: header!.promptRetainedRow)
        XCTAssertEqual(view.viewportOffset, view.scrollbackLength, "scrolled to top of retained scrollback")
    }

    func testStickyCommandHeaderInvalidatedOnCheckpointRestore() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git log\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "commit \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        XCTAssertNotNil(view.currentStickyCommandHeader())
        XCTAssertGreaterThan(view.trackedCommandsCountForTesting, 0)

        // Clean terminal exports checkpoint
        let cleanView = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let checkpoint = try cleanView.exportCheckpoint()

        // Importing checkpoint invalidates trackedCommands and sticky header
        try view.importCheckpoint(checkpoint)
        XCTAssertNil(view.currentStickyCommandHeader(), "sticky header must be nil after checkpoint restore")
        XCTAssertEqual(view.trackedCommandsCountForTesting, 0, "tracked commands must be empty after checkpoint restore")
    }

    func testStickyCommandHeaderPrunedWhenOutputLeavesScrollback() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.core.setScrollbackLimit(lines: 10)

        // Command 1
        var input1 = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}old-cmd\r\n\u{1b}]133;C\u{07}"
        for i in 1...15 {
            input1 += "old output \(i)\r\n"
        }
        input1 += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input1.utf8))
        _ = view.currentStickyCommandHeader()
        XCTAssertEqual(view.activeTrackedCommandsCountForTesting, 1)

        // Command 2 with enough output to evict all of Command 1's output past firstRetainedLine
        var input2 = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}new-cmd\r\n\u{1b}]133;C\u{07}"
        for i in 1...80 {
            input2 += "new output \(i)\r\n"
        }
        input2 += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input2.utf8))

        // Trigger evaluation which prunes evicted commands
        _ = view.currentStickyCommandHeader()

        // Old command whose output completely left scrollback is marked as having no output (sentinel)
        // Only new-cmd should remain active
        XCTAssertEqual(view.activeTrackedCommandsCountForTesting, 1)
        XCTAssertTrue(view.trackedCommandsForTesting[1]?.hasNoOutput == true)
    }

    func testStickyCommandHeaderResumesRunningCommandAfterCheckpointRestore() throws {
        let view1 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}find /\r\n\u{1b}]133;C\u{07}"
        for i in 1...60 {
            input += "file \(i)\r\n"
        }
        // Note: command is still running (no 133;D)
        view1.feed(data: Data(input.utf8))

        let checkpoint = try view1.exportCheckpoint()

        // View 2 imports checkpoint
        let view2 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        try view2.importCheckpoint(checkpoint)

        // Scrolled into output
        view2.scrollViewportUp(lines: 10)
        let header1 = view2.currentStickyCommandHeader()
        XCTAssertNotNil(header1)
        XCTAssertEqual(header1?.command, "find /")
        XCTAssertEqual(header1?.status, 0, "status must be running (0)")

        // Continued output after restore advances lastOutputAbsLine
        var moreOutput = ""
        for i in 61...110 {
            moreOutput += "file \(i)\r\n"
        }
        view2.feed(data: Data(moreOutput.utf8))

        // Viewport moves past the old checkpoint endpoint;
        // header must still be present because command is still running and owns visible rows
        view2.scrollViewportUp(lines: 20)
        let header2 = view2.currentStickyCommandHeader()
        XCTAssertNotNil(header2, "header must not disappear as running command output continues after restore")
        XCTAssertEqual(header2?.command, "find /")
        XCTAssertEqual(header2?.status, 0, "status remains running (0)")

        // Command ends with exit code 0
        view2.feed(data: Data("\u{1b}]133;D;0\u{07}".utf8))
        let header3 = view2.currentStickyCommandHeader()
        XCTAssertNotNil(header3)
        XCTAssertEqual(header3?.command, "find /")
        XCTAssertEqual(header3?.status, 1, "status transitions to success (1)")
    }

    func testStickyCommandHeaderCachesZeroOutputCommandsWithoutRepeatedQueries() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}true\r\n\u{1b}]133;C\u{07}\u{1b}]133;D;0\u{07}\u{1b}]133;A\u{07}$ "
        view.feed(data: Data(input.utf8))

        // Zero-output command should produce no sticky header
        XCTAssertNil(view.currentStickyCommandHeader(), "zero-output command must never pin sticky header")

        // Zero-output command is cached in trackedCommands as a no-output sentinel
        XCTAssertEqual(view.activeTrackedCommandsCountForTesting, 0, "no active commands with output")
        XCTAssertEqual(view.trackedCommandsCountForTesting, 1, "command is cached as sentinel")
        XCTAssertTrue(view.trackedCommandsForTesting[1]?.hasNoOutput == true, "sentinel hasNoOutput is true")

        // Repeated evaluations preserve the sentinel without repeatedly scanning grid
        _ = view.currentStickyCommandHeader()
        XCTAssertEqual(view.trackedCommandsCountForTesting, 1)
        XCTAssertTrue(view.trackedCommandsForTesting[1]?.hasNoOutput == true)
    }

    func testCheckpointRestoreWithSubstantialHistoryDoesNotMaterializeAllOutputs() throws {
        let view1 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Create 20 commands in history
        for cmdIdx in 1...20 {
            var cmd = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}echo cmd\(cmdIdx)\r\n\u{1b}]133;C\u{07}"
            for line in 1...3 {
                cmd += "out \(cmdIdx)_\(line)\r\n"
            }
            cmd += "\u{1b}]133;D;0\u{07}"
            view1.feed(data: Data(cmd.utf8))
        }
        // At bottom, prompt 21
        view1.feed(data: Data("\u{1b}]133;A\u{07}$ ".utf8))

        let checkpoint = try view1.exportCheckpoint()

        let view2 = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        try view2.importCheckpoint(checkpoint)

        // Update scroller / evaluate sticky header
        view2.updateScroller()

        // trackedCommands must NOT have materialized all 20 historical commands!
        // At most the single command intersecting the viewport is resolved.
        XCTAssertLessThanOrEqual(
            view2.trackedCommandsCountForTesting,
            1,
            "Restoring checkpoint must not synchronously extract all historical commands; resolved \(view2.trackedCommandsCountForTesting)"
        )
    }

    func testStickyCommandHeaderLegibleWithLightTheme() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let lightBg = NSColor.white.cgColor
        let darkFg = NSColor(calibratedRed: 0.125, green: 0.13, blue: 0.133, alpha: 1.0).cgColor // #202122
        view.theme = TerminalTheme(background: lightBg, foreground: darkFg)

        XCTAssertTrue(view.isLightTheme, "theme must be detected as light theme")

        // Feed command with 40 lines of output
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git diff\r\n\u{1b}]133;C\u{07}"
        for i in 1...40 {
            input += "diff line \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        view.updateScroller()
        XCTAssertFalse(view.stickyHeaderLayer.isHidden, "sticky header should be visible")

        guard let headerBg = view.stickyHeaderLayer.backgroundColor,
              let headerNsColor = NSColor(cgColor: headerBg)?.usingColorSpace(.sRGB),
              let textNsColor = NSColor(cgColor: view.stickyHeaderTextLayer.foregroundColor ?? darkFg)?.usingColorSpace(.sRGB) else {
            XCTFail("Could not inspect header colors")
            return
        }

        let bgLuminance = 0.2126 * headerNsColor.redComponent + 0.7152 * headerNsColor.greenComponent + 0.0722 * headerNsColor.blueComponent
        let textLuminance = 0.2126 * textNsColor.redComponent + 0.7152 * textNsColor.greenComponent + 0.0722 * textNsColor.blueComponent

        XCTAssertGreaterThan(bgLuminance, 0.7, "header background must be light on light theme; got \(bgLuminance)")
        XCTAssertLessThan(textLuminance, 0.3, "header text must be dark on light theme; got \(textLuminance)")
        XCTAssertGreaterThan(bgLuminance - textLuminance, 0.5, "contrast difference between background and text must be high")
    }

    func testStickyCommandHeaderDisabledDoesNotTrackCommands() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.stickyCommandHeaderEnabled = false

        // Run command while sticky headers are disabled
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}find .\r\n\u{1b}]133;C\u{07}"
        for i in 1...50 {
            input += "file \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        // When disabled, no commands should be tracked in memory
        XCTAssertEqual(view.trackedCommandsCountForTesting, 0, "trackedCommands must remain empty when disabled")
        XCTAssertNil(view.currentStickyCommandHeader())
    }

    func testStickyCommandHeaderSuppressedOnMultilineCommandContinuationRows() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Multiline command:
        // Line 0: prompt + input line 1
        // Line 1: input continuation line 2
        // Line 2: input continuation line 3
        // Line 3..52: output lines
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}cat << 'EOF' | grep -v exclude\r\n"
        input += "continuation row 1\r\n"
        input += "continuation row 2\r\n"
        input += "\u{1b}]133;C\u{07}"
        for i in 1...50 {
            input += "output row \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        let totalScrollback = Int(view.core.scrollbackLen())
        XCTAssertGreaterThan(totalScrollback, 10, "terminal should have accumulated scrollback")

        // Viewport at bottom: sitting in output, sticky header must be pinned
        let bottomHeader = view.currentStickyCommandHeader()
        XCTAssertNotNil(bottomHeader, "must be pinned while in output")
        XCTAssertEqual(bottomHeader?.status, 1)

        // Scroll so viewport top sits on input continuation row 1 (row 1)
        // vpTop = totalScrollback - offset -> offset = totalScrollback - 1
        view.scrollToOffset(totalScrollback - 1)
        XCTAssertNil(
            view.currentStickyCommandHeader(),
            "sticky header must be suppressed when viewport top sits on input continuation row 1"
        )

        // Scroll so viewport top sits on input continuation row 2 (row 2)
        view.scrollToOffset(totalScrollback - 2)
        XCTAssertNil(
            view.currentStickyCommandHeader(),
            "sticky header must be suppressed when viewport top sits on input continuation row 2"
        )

        // Scroll so viewport top sits on prompt line (row 0)
        view.scrollToOffset(totalScrollback)
        XCTAssertNil(
            view.currentStickyCommandHeader(),
            "sticky header must be suppressed when prompt line is visible"
        )

        // Scroll so viewport top sits on first output row (row 3)
        view.scrollToOffset(totalScrollback - 3)
        let outputHeader = view.currentStickyCommandHeader()
        XCTAssertNotNil(
            outputHeader,
            "sticky header must pin once viewport top reaches command output"
        )
        XCTAssertEqual(outputHeader?.status, 1)
    }

    func testStickyCommandHeaderSuppressedOnSecondaryPromptContinuationRows() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Secondary prompt continuation (OSC 133;A;k=s)
        var input = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}python3 -c '\r\n"
        input += "\u{1b}]133;A;k=s\u{07}> \u{1b}]133;B\u{07}print(\"hello\")'\r\n"
        input += "\u{1b}]133;C\u{07}"
        for i in 1...50 {
            input += "output \(i)\r\n"
        }
        input += "\u{1b}]133;D;0\u{07}"
        view.feed(data: Data(input.utf8))

        let totalScrollback = Int(view.core.scrollbackLen())
        XCTAssertGreaterThan(totalScrollback, 10)

        // Viewport at secondary prompt continuation row (row 1)
        view.scrollToOffset(totalScrollback - 1)
        XCTAssertNil(
            view.currentStickyCommandHeader(),
            "sticky header must be suppressed on secondary prompt continuation row"
        )

        // Viewport at output row (row 2)
        view.scrollToOffset(totalScrollback - 2)
        XCTAssertNotNil(
            view.currentStickyCommandHeader(),
            "sticky header must pin once scrolled into output"
        )
    }
}
#endif


