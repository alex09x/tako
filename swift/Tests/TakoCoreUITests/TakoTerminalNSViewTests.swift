/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest
@testable import TakoCoreUI

final class TakoTerminalNSViewTests: XCTestCase {

    @MainActor func drawForTesting(_ view: TakoTerminalNSView) {
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

}
