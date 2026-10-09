/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalViewTests {
// MARK: - The surface a detachable host needs
//
// A phone view is torn down and rebuilt whenever the OS decides, and the
// session outlives it. So the host copies the buffer out as text, stores
// where the user was, and puts them back. None of that survives being
// expressed in viewport coordinates: the viewport is the part you can see,
// and the part you can see is neither what you are copying nor where you
// were.

    func testBufferTextCarriesScrollbackNotJustTheVisibleRows() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        for i in 0..<50 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }

        let text = view.bufferText
        XCTAssertTrue(text.contains("line0"), "copy lost the history")
        XCTAssertTrue(text.contains("line49"), "copy lost the newest line")
    }

    func testScrollPositionRoundTripsThroughTheHost() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        for i in 0..<60 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }
        view.scrollViewportUp(lines: 20)

        let saved = view.scrollPosition
        XCTAssertGreaterThan(saved, 0)
        XCTAssertLessThan(saved, 1)

        view.scrollViewportToBottom()
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.0001)

        view.scrollPosition = saved
        XCTAssertEqual(view.viewportOffset, 20, "restoring landed on a different line")
    }

    func testAFreshViewIsAtTheTail() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        XCTAssertEqual(view.scrollPosition, 1, accuracy: 0.0001)
    }

    func testOsc52ReachesTheHostRatherThanThePasteboard() {
        // Whether a program on the far end of a socket may replace what the
        // user last copied is the host's call, so the view only reports it.
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let payload = Data("hello".utf8).base64EncodedString()
        view.feed(data: Data("\u{1b}]52;c;\(payload)\u{07}".utf8))

        XCTAssertEqual(delegate.clipboardCopies, ["hello"])
    }

    func testWorkingDirectoryReachesTheHost() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]7;file:///Users/alex\u{07}".utf8))

        XCTAssertEqual(delegate.lastWorkingDirectory, "file:///Users/alex")
    }

    func testContentChangesAreAnnouncedOncePerBatchNotPerCell() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("hello world".utf8))

        XCTAssertEqual(delegate.contentChangeCount, 1)
    }

    func testAnUnchangedViewportIsNotReportedAsScrolling() {
        // Output while pinned to the tail leaves the position at 1, and a
        // host storing it should not be woken for every batch.
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        for i in 0..<20 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }

        XCTAssertTrue(delegate.scrollPositions.isEmpty,
                      "reported \(delegate.scrollPositions.count) scrolls without moving")
    }

    func testScrollingBackIsReportedToTheHost() {
        let view = TakoTerminalView(core: TakoCore(cols: 40, rows: 6))
        for i in 0..<50 {
            view.feed(data: Data("line\(i)\r\n".utf8))
        }
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.scrollViewportUp(lines: 10)
        view.feed(data: Data("more\r\n".utf8))

        XCTAssertFalse(delegate.scrollPositions.isEmpty, "the host never heard about the scroll")
        XCTAssertLessThan(delegate.scrollPositions.last ?? 1, 1)
    }

    func testSplitOrAsynchronouslyQueuedEscapeStreamCannotMakeSwiftRoutingDisagreeWithCoreState() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()
        let cellH = view.renderer.metrics.cellHeight

        // 1. Feed split escape sequence across feeds: "\e[?10" followed by "49h"
        view.feed(data: Data("\u{1b}[?10".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        view.feed(data: Data("49h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        // Gesture immediately routes to alternate screen (arrow keys)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[A")

        // 2. Split exit escape sequence across feeds: "\e[?10" followed by "49l"
        view.feed(data: Data("\u{1b}[?10".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        view.feed(data: Data("49l".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)

        // Gesture immediately routes to primary screen (local scrollback, no delegate input)
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        // 3. Asynchronously queued stream with enqueue(data:)
        let exp = expectation(description: "enqueued modes applied via title sentinel")
        delegate.onTitleChange = { title in
            if title == "sentinel" {
                exp.fulfill()
            }
        }
        view.enqueue(data: Data("\u{1b}[?1049h\u{1b}[?1007l\u{1b}]0;sentinel\u{07}".utf8))

        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertFalse(view.isAlternateScroll)
        XCTAssertEqual(view.isAlternateScreen, view.core.modes().alternateScreen)
        XCTAssertEqual(view.isAlternateScroll, view.core.modes().alternateScroll)

        // Because mode 1007 is disabled, pan gesture produces no arrow keys
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    func testTakoTerminalViewPanGestureInAlternateScreenSendsInputToDelegate() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        // 1. Primary screen pan: delegates receive no sendInputData, viewport moves
        let history = (1...50).map { "Primary line \($0)\r\n" }.joined()
        view.feed(data: Data(history.utf8))
        XCTAssertFalse(view.isAlternateScreen)

        let panSel = Selector(("handlePan:"))
        let pan = MockPanGestureRecognizer()

        // Panning down (translation.y > 0) -> scroll up into history
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        let cellH = view.renderer.metrics.cellHeight
        pan.setTranslation(CGPoint(x: 0, y: cellH * 3), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Primary screen pan must not send input data to PTY")
        XCTAssertGreaterThan(view.viewportOffset, 0, "Primary screen pan must move local viewport")

        // 2. Enter alternate screen (e.g. Claude Code / TUI agent)
        view.feed(data: Data("\u{1b}[?1049h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)
        delegate.inputDataReceived = Data()

        // Alternate screen pan down (translation.y > 0) -> should send Up Arrow keys
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH * 2), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Alternate screen pan must produce input data for the agent/app")
        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[A\u{1b}[A")

        // Alternate screen pan up (translation.y < 0) -> should send Down Arrow keys
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: -cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}[B")

        // 3. Application cursor key mode (DECCKM \e[?1h)
        view.feed(data: Data("\u{1b}[?1h".utf8))
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertEqual(String(data: delegate.inputDataReceived, encoding: .utf8), "\u{1b}OA")

        // 4. Mouse tracking enabled (\e[?1000h\e[?1006h)
        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        delegate.inputDataReceived = Data()
        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        let mouseString = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(mouseString.hasPrefix("\u{1b}[<64;"), "Mouse tracking should produce SGR wheel up: \(mouseString)")

        // 5. Exit alternate screen -> returns to normal primary screen scrolling
        view.feed(data: Data("\u{1b}[?1049l\u{1b}[?1000l\u{1b}[?1006l".utf8))
        XCTAssertFalse(view.isAlternateScreen)
        delegate.inputDataReceived = Data()

        pan.state = .began
        _ = view.perform(panSel, with: pan)
        pan.state = .changed
        pan.setTranslation(CGPoint(x: 0, y: cellH), in: view)
        _ = view.perform(panSel, with: pan)
        pan.state = .ended
        _ = view.perform(panSel, with: pan)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Returning to primary screen without mouse tracking must not send input data")
    }
}
#endif
