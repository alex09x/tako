import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class MockTerminalNSViewDelegate: TakoTerminalNSViewDelegate {
    var inputDataReceived = Data()
    var deviceReplyDataReceived = Data()
    var lastResizedCols: Int?
    var lastResizedRows: Int?
    var resizeCount = 0
    var lastTitle: String?
    var onTitleChange: ((String) -> Void)?
    var bellCount = 0
    var commandStartCount = 0
    var commandExitCodes: [Int32?] = []
    var clipboardCopies: [String] = []
    var lastWorkingDirectory: String?
    var scrollPositions: [Double] = []
    var contentChangeCount = 0

    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
        inputDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
        deviceReplyDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {
        resizeCount += 1
        lastResizedCols = cols
        lastResizedRows = rows
    }

    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String) {
        lastTitle = title
        onTitleChange?(title)
    }

    func terminalViewDidBell(_ view: TakoTerminalNSView) {
        bellCount += 1
    }

    func terminalViewCommandDidStart(_ view: TakoTerminalNSView) {
        commandStartCount += 1
    }

    func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?) {
        commandExitCodes.append(exitCode)
    }

    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String) {
        clipboardCopies.append(text)
    }

    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String) {
        lastWorkingDirectory = url
    }

    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double) {
        scrollPositions.append(position)
    }

    func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {
        contentChangeCount += 1
    }
}

final class TakoTerminalNSViewTests: XCTestCase {

    @MainActor private func drawForTesting(_ view: TakoTerminalNSView) {
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            TakoTerminalNSView.isMetalDisabledForTesting = true
        }
    }

    // MARK: - Construction & Transport

    func testInitializationWithoutChildProcess() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            XCTAssertEqual(view.cols, 80)
            XCTAssertEqual(view.rows, 24)
            XCTAssertEqual(view.title, "")
            XCTAssertNil(view.workingDirectory)
            XCTAssertFalse(view.isAlternateScreen)
            XCTAssertTrue(view.isAlternateScroll)
        }
    }

    func testSynchronousFeed() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("Hello Tako Terminal!\r\nLine 2".utf8))
            let text = view.plainText(startRow: 0, maxRows: 2)
            XCTAssertTrue(text.contains("Hello Tako Terminal!"))
            XCTAssertTrue(text.contains("Line 2"))
            XCTAssertGreaterThanOrEqual(delegate.contentChangeCount, 1)
        }
    }

    func testAsynchronousEnqueue() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.enqueue(data: Data("Enqueued bulk text output\r\n".utf8))
            view.parserCoordinator.waitForParserQuiescence()

            let exp = expectation(description: "drain outcome")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 1.0)

            let text = view.plainText(startRow: 0, maxRows: 1)
            XCTAssertTrue(text.contains("Enqueued bulk text output"))
        }
    }

    func testResetAndClearScreen() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Text to be cleared".utf8))
            XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Text to be cleared"))

            view.clearScreen()
            let textAfterClear = view.plainText(startRow: 0, maxRows: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(textAfterClear.isEmpty)

            view.feed(data: Data("Before reset".utf8))
            view.reset()
            let textAfterReset = view.plainText(startRow: 0, maxRows: 1).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(textAfterReset.isEmpty)
        }
    }

    // MARK: - Delegate Callbacks

    func testDelegateDeviceReply() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[c".utf8))
            XCTAssertFalse(delegate.deviceReplyDataReceived.isEmpty)
            let replyString = String(data: delegate.deviceReplyDataReceived, encoding: .utf8) ?? ""
            XCTAssertTrue(replyString.hasPrefix("\u{1b}[?"))
        }
    }

    func testDelegateTitleChange() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}]0;Project Workspace\u{07}".utf8))
            XCTAssertEqual(delegate.lastTitle, "Project Workspace")
            XCTAssertEqual(view.title, "Project Workspace")
        }
    }

    func testDelegateBell() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{07}".utf8))
            XCTAssertEqual(delegate.bellCount, 1)
        }
    }

    func testDelegateCommandLifecycle() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}]133;C\u{07}".utf8))
            XCTAssertEqual(delegate.commandStartCount, 1)

            view.feed(data: Data("\u{1b}]133;D;0\u{07}".utf8))
            XCTAssertEqual(delegate.commandExitCodes, [0])
        }
    }

    func testDelegateClipboardCopyOSC52() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}]52;c;SGVsbG8=\u{07}".utf8))
            XCTAssertEqual(delegate.clipboardCopies, ["Hello"])
        }
    }

    func testDelegateWorkingDirectoryOSC7() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}]7;file://localhost/Volumes/worktrees/repo\u{07}".utf8))
            XCTAssertEqual(delegate.lastWorkingDirectory, "/Volumes/worktrees/repo")
            XCTAssertEqual(view.workingDirectory, "/Volumes/worktrees/repo")
        }
    }

    func testDelegateResize() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.setFrameSize(NSSize(width: 400, height: 300))
            view.flushPendingResizeForTesting()

            XCTAssertNotNil(delegate.lastResizedCols)
            XCTAssertNotNil(delegate.lastResizedRows)
            XCTAssertEqual(view.cols, delegate.lastResizedCols)
            XCTAssertEqual(view.rows, delegate.lastResizedRows)
        }
    }

    // MARK: - Keyboard Input

    func testKeyboardInputEncoding() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            let eventA = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )!
            view.keyDown(with: eventA)
            XCTAssertEqual(delegate.inputDataReceived, Data("a".utf8))
            delegate.inputDataReceived.removeAll()

            let eventReturn = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )!
            view.keyDown(with: eventReturn)
            XCTAssertEqual(delegate.inputDataReceived, Data("\r".utf8))
            delegate.inputDataReceived.removeAll()

            let eventUp = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 126
            )!
            view.keyDown(with: eventUp)
            XCTAssertEqual(delegate.inputDataReceived, Data("\u{1b}[A".utf8))
            delegate.inputDataReceived.removeAll()

            let eventCtrlC = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\u{03}",
                charactersIgnoringModifiers: "c",
                isARepeat: false,
                keyCode: 8
            )!
            view.keyDown(with: eventCtrlC)
            XCTAssertEqual(delegate.inputDataReceived, Data([0x03]))
            delegate.inputDataReceived.removeAll()
        }
    }

    // MARK: - NSTextInputClient

    func testNSTextInputClientMarkedText() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            XCTAssertFalse(view.hasMarkedText())

            view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 3))

            view.unmarkText()
            XCTAssertFalse(view.hasMarkedText())
        }
    }

    func testNSTextInputClientInsertText() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.setMarkedText("nih", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))

            XCTAssertFalse(view.hasMarkedText())
            XCTAssertEqual(delegate.inputDataReceived, Data("你好".utf8))
        }
    }

    func testFirstRectCalculation() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let rect = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            XCTAssertGreaterThan(rect.size.width, 0)
            XCTAssertGreaterThan(rect.size.height, 0)
        }
    }

    // MARK: - Selection & Copy/Paste

    func testSelectionAndCopy() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Copied Sample Text\r\n".utf8))

            var copiedText: String?
            view.copyStringConsumer = { text in copiedText = text }

            view.core.startSelection(row: 0, col: 0, mode: .linear)
            view.core.extendSelection(row: 0, col: 5)

            XCTAssertEqual(view.selectedText, "Copied")
            view.copy(nil)
            XCTAssertEqual(copiedText, "Copied")
        }
    }

    func testPasteAction() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.pasteStringProvider = { "Pasted String" }
            view.paste(nil)

            XCTAssertEqual(delegate.inputDataReceived, Data("Pasted String".utf8))
        }
    }

    func testBracketedPasteMode() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[?2004h".utf8))

            view.pasteStringProvider = { "line1\nline2" }
            view.paste(nil)

            let pastedData = delegate.inputDataReceived
            let pastedStr = String(data: pastedData, encoding: .utf8) ?? ""
            XCTAssertTrue(pastedStr.hasPrefix("\u{1b}[200~"))
            XCTAssertTrue(pastedStr.hasSuffix("\u{1b}[201~"))
            XCTAssertTrue(pastedStr.contains("line1\rline2"))
        }
    }

    // MARK: - Mouse Reporting vs Local Selection

    func testMouseReportingWhenEnabled() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))

            let mouseDownEvent = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: 50, y: 550),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1.0
            )!

            view.mouseDown(with: mouseDownEvent)
            XCTAssertFalse(delegate.inputDataReceived.isEmpty)
            let seq = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
            XCTAssertTrue(seq.hasPrefix("\u{1b}[<0;"))
            XCTAssertTrue(seq.hasSuffix("M"))
        }
    }

    // MARK: - Synchronized Output

    func testSynchronizedOutputHolding() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = MockTerminalNSViewDelegate()
            view.delegate = delegate

            view.feed(data: Data("\u{1b}[?2026h".utf8))
            XCTAssertTrue(view.core.isSynchronizedOutputActive())

            view.feed(data: Data("Mid-sync text".utf8))

            view.feed(data: Data("\u{1b}[?2026l".utf8))
            XCTAssertFalse(view.core.isSynchronizedOutputActive())
            XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Mid-sync text"))
        }
    }

    // MARK: - Presentation pause and cursor blink

    func testPresentationInvalidationDoesNotReenterDrive() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            view.needsDisplay = true

            XCTAssertTrue(view.redrawPending)
        }
    }

    func testPresentationPauseRetainsDamageAndPresentsOnlyAfterResume() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.isPresentationPaused = true
            view.feed(data: Data("arrived while hidden".utf8))

            XCTAssertTrue(view.isPresentationPaused)
            XCTAssertTrue(view.redrawPending)
            XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("arrived while hidden"))

            let fetchedWhilePaused = view.frameFetchCount
            view.redrawNow()
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused, "paused draw paths must not fetch a frame")

            view.isPresentationPaused = false
            XCTAssertFalse(view.isPresentationPaused)
            XCTAssertTrue(view.redrawPending, "damage accrued while paused is still owed")

            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused + 1)
            XCTAssertFalse(view.redrawPending)

            drawForTesting(view)
            XCTAssertEqual(
                view.frameFetchCount,
                fetchedWhilePaused + 1,
                "one coalesced presentation debt must fetch exactly one frame")
        }
    }

    func testPresentationPauseTransitionsAreIdempotent() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.isPresentationPaused = true
            view.isPresentationPaused = true
            view.feed(data: Data("coalesced".utf8))

            let fetchedWhilePaused = view.frameFetchCount
            view.displayLinkFired()
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused)

            view.isPresentationPaused = false
            view.isPresentationPaused = false
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, fetchedWhilePaused + 1)
            XCTAssertFalse(view.redrawPending)
        }
    }

    func testPresentationRateLimitAttachedCPUFallbackUsesOneShotAndRetainsLatestDebt() {
        MainActor.assumeIsolated {
            var now: TimeInterval = 1
            var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: .borderless,
                backing: .buffered,
                defer: false)
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = view
            view.setPresentationRateLimitClockForTesting { now }
            view.setPresentationThrottleSchedulerForTesting { delay, work in
                scheduled.append((delay, work))
            }
            view.maximumPresentationFramesPerSecond = 5

            view.scheduleRedraw()
            drawForTesting(view)
            let first = view.frameFetchCount
            view.scheduleRedraw()
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, first)
            XCTAssertTrue(view.redrawPending, "a capped draw must remain owed")
            XCTAssertTrue(view.hasPresentationThrottleForTesting)
            XCTAssertEqual(scheduled.count, 1, "rapid attached damage gets exactly one coalesced wakeup")
            XCTAssertEqual(scheduled[0].delay, 0.2, accuracy: 0.000_001)

            now += 0.2
            scheduled.removeFirst().work.perform()
            drawForTesting(view)
            XCTAssertEqual(view.frameFetchCount, first + 1)
            XCTAssertFalse(view.redrawPending)
            XCTAssertFalse(view.hasPresentationThrottleForTesting, "the final delayed frame leaves no idle wakeup")

            // Explicit AppKit paint after the deadline cancels the stale
            // one-shot instead of retaining a needless idle callback.
            view.scheduleRedraw()
            XCTAssertEqual(scheduled.count, 1)
            now += 0.2
            drawForTesting(view)
            XCTAssertTrue(scheduled.removeFirst().work.isCancelled)
            XCTAssertFalse(view.hasPresentationThrottleForTesting)

            // Pause and detach preserve debt but cancel the outstanding work.
            view.scheduleRedraw()
            let pausedWork = scheduled.removeFirst().work
            view.isPresentationPaused = true
            XCTAssertTrue(pausedWork.isCancelled)
            XCTAssertFalse(view.hasPresentationThrottleForTesting)
            view.isPresentationPaused = false
            XCTAssertEqual(scheduled.count, 1)
            let resumedWork = scheduled.removeFirst().work

            window.contentView = nil
            XCTAssertTrue(resumedWork.isCancelled)
            XCTAssertFalse(view.hasPresentationThrottleForTesting)
            XCTAssertTrue(view.redrawPending, "detach retains the latest unsatisfied frame")

            window.contentView = view
            XCTAssertEqual(scheduled.count, 1, "reattach resumes the retained debt")
            now += 0.2
            scheduled.removeFirst().work.perform()
            drawForTesting(view)
            XCTAssertFalse(view.redrawPending)

            view.scheduleRedraw()
            let rateChangeWork = scheduled.removeFirst().work
            view.maximumPresentationFramesPerSecond = 10
            XCTAssertTrue(rateChangeWork.isCancelled)
            XCTAssertEqual(scheduled.count, 1)
            let clearWork = scheduled.removeFirst().work
            view.maximumPresentationFramesPerSecond = nil
            XCTAssertTrue(clearWork.isCancelled)
            drawForTesting(view)
            XCTAssertFalse(view.redrawPending)
            XCTAssertFalse(view.hasPresentationThrottleForTesting, "an idle attached surface retains no scheduled work")
        }
    }

    func testPresentationRateLimitDestroyCancelsAttachedOneShot() {
        MainActor.assumeIsolated {
            let now: TimeInterval = 1
            var scheduled: [DispatchWorkItem] = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: .borderless,
                backing: .buffered,
                defer: false)
            weak var releasedView: TakoTerminalNSView?

            autoreleasepool {
                let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                releasedView = view
                window.contentView = view
                view.setPresentationRateLimitClockForTesting { now }
                view.setPresentationThrottleSchedulerForTesting { _, work in scheduled.append(work) }
                view.maximumPresentationFramesPerSecond = 5
                drawForTesting(view)
                view.scheduleRedraw()
                XCTAssertEqual(scheduled.count, 1)
                window.contentView = nil
            }

            XCTAssertTrue(scheduled[0].isCancelled)
            XCTAssertNil(releasedView, "a detached destroyed view must not retain a throttle callback")
        }
    }

    func testPresentationPauseSuspendsAndRestoresExactlyOneBlinkTimer() throws {
        try MainActor.assumeIsolated {
            var blinking = TerminalTheme.takoDefault
            blinking.cursorBlink = true
            let view = TakoTerminalNSView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                theme: blinking)
            let originalTimer = try XCTUnwrap(view.blinkTimer)

            view.isPresentationPaused = true
            XCTAssertNil(view.blinkTimer)

            view.theme = blinking
            XCTAssertNil(view.blinkTimer, "theme updates must not wake a paused surface")

            view.isPresentationPaused = false
            let resumedTimer = try XCTUnwrap(view.blinkTimer)
            XCTAssertFalse(originalTimer === resumedTimer)

            view.isPresentationPaused = false
            XCTAssertTrue(resumedTimer === view.blinkTimer, "an idempotent resume must keep one timer")
        }
    }

    func testDisabledCursorBlinkOwnsNoTimerAcrossThemeChanges() {
        MainActor.assumeIsolated {
            var noBlink = TerminalTheme.takoDefault
            noBlink.cursorBlink = false
            let view = TakoTerminalNSView(
                frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                theme: noBlink)
            XCTAssertNil(view.blinkTimer)

            var blinking = noBlink
            blinking.cursorBlink = true
            view.theme = blinking
            XCTAssertNotNil(view.blinkTimer)

            view.theme = noBlink
            XCTAssertNil(view.blinkTimer)
            view.isPresentationPaused = true
            view.isPresentationPaused = false
            XCTAssertNil(view.blinkTimer, "resuming must not recreate a disabled blink timer")
        }
    }

    // MARK: - Accessibility & Teardown

    func testAccessibilityProperties() {
        MainActor.assumeIsolated {
            let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Accessibility Content".utf8))

            XCTAssertTrue(view.plainText(startRow: 0, maxRows: view.rows).contains("Accessibility Content"))
            XCTAssertEqual(view.accessibilityRole(), .textArea)
            XCTAssertEqual(view.accessibilityLabel(), "Terminal")
        }
    }

    func testDeterministicTeardown() {
        MainActor.assumeIsolated {
            var view: TakoTerminalNSView? = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            view?.feed(data: Data("Transient view content".utf8))
            XCTAssertNotNil(view)
            view = nil
            XCTAssertNil(view)
        }
    }
}
#endif
