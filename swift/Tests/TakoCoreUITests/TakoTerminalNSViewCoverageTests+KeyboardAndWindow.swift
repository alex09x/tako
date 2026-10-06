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
import Carbon
import XCTest
@testable import TakoCoreUI

extension TakoTerminalNSViewCoverageTests {

    func testMetalColorAndPaletteEncodings() {
        let theme = TerminalTheme.takoDefault
        let paletteDisplay = TakoTerminalNSView.metalPalette(for: theme, encoding: .displayEncoded)
        XCTAssertEqual(paletteDisplay.background.w, Float(theme.backgroundOpacity))

        let paletteLinear = TakoTerminalNSView.metalPalette(for: theme, encoding: .linear)
        XCTAssertEqual(paletteLinear.background.w, Float(theme.backgroundOpacity))

        let gray1 = CGColor(gray: 0.5, alpha: 1.0)
        let color1 = TakoTerminalNSView.metalColor(gray1, alpha: 0.8, encoding: .displayEncoded)
        XCTAssertEqual(color1.w, 0.8)

        let rgb = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.9)
        let colorRGB = TakoTerminalNSView.metalColor(rgb, encoding: .displayEncoded)
        XCTAssertEqual(colorRGB.w, 0.9)

        let colorRGBAlpha = TakoTerminalNSView.metalColor(rgb, alpha: 0.5, encoding: .linear)
        XCTAssertEqual(colorRGBAlpha.w, 0.5)

        let size = TakoTerminalNSView.drawableSize(for: CGSize(width: 800.7, height: 600.2), scale: 2.0)
        XCTAssertEqual(size.width, 1601.0)
        XCTAssertEqual(size.height, 1200.0)

        let clampedSize = TakoTerminalNSView.drawableSize(for: CGSize(width: 0, height: 0), scale: 0.5)
        XCTAssertEqual(clampedSize.width, 1.0)
        XCTAssertEqual(clampedSize.height, 1.0)
    }

    // MARK: - 7. Window, Backing, Tracking and Resizing

    func testWindowLifecycleAndBackingProperties() {
        let (view, window) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.viewDidChangeBackingProperties()
        view.viewDidHide()
        view.viewDidUnhide()

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        let unrelatedWindow = NSWindow()
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: unrelatedWindow
        )

        view.setFrameSize(NSSize(width: 500, height: 350))
        view.setFrameSize(NSSize(width: 500, height: 350))
        view.flushPendingResizeForTesting()
        XCTAssertNotNil(delegate.lastResizedCols)
        XCTAssertNotNil(delegate.lastResizedRows)

        view.updateTrackingAreas()
        XCTAssertFalse(view.trackingAreas.isEmpty)

        window.contentView = nil
        XCTAssertNil(view.window)
    }

    // MARK: - 8. First Responder and Focus

    func testFirstResponderTransitionsAndMarkedTextCleanup() {
        let (view, window) = makeHostedView()
        window.makeFirstResponder(view)

        let exp = expectation(description: "responder activation")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        view.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        _ = view.resignFirstResponder()
        XCTAssertFalse(view.hasMarkedText())
    }

    func testShouldHoldInputContextPermutations() {
        XCTAssertTrue(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: true, isFirstResponder: true, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: false, isKeyWindow: true, isFirstResponder: true, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: false, isFirstResponder: true, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: true, isFirstResponder: false, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: true, isFirstResponder: true, isHidden: true))
    }

    // MARK: - 9. Keyboard Input Encoding

    func testKeyboardInputNamedKeysAndModifiers() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        let namedKeyCodes: [(UInt16, String)] = [
            (49, " "),      // Space
            (48, "\t"),     // Tab
            (53, "\u{1b}"), // Escape
            (51, "\u{7f}"), // Backspace
            (126, "\u{1b}[A"), // Up
            (125, "\u{1b}[B"), // Down
            (124, "\u{1b}[C"), // Right
            (123, "\u{1b}[D"), // Left
            (115, "\u{1b}[H"), // Home
            (119, "\u{1b}[F"), // End
            (116, "\u{1b}[5~"), // PageUp
            (121, "\u{1b}[6~"), // PageDown
            (117, "\u{1b}[3~"), // Delete forward
            (122, "\u{1b}OP"),  // F1
            (120, "\u{1b}OQ"),  // F2
            (99, "\u{1b}OR"),   // F3
            (118, "\u{1b}OS"),  // F4
            (96, "\u{1b}[15~"), // F5
            (97, "\u{1b}[17~"), // F6
            (98, "\u{1b}[18~"), // F7
            (100, "\u{1b}[19~"), // F8
            (101, "\u{1b}[20~"), // F9
            (109, "\u{1b}[21~"), // F10
            (103, "\u{1b}[23~"), // F11
            (111, "\u{1b}[24~"), // F12
        ]

        for (keyCode, expectedPrefix) in namedKeyCodes {
            delegate.inputDataReceived.removeAll()
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )!
            view.keyDown(with: event)
            let received = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
            XCTAssertFalse(received.isEmpty, "No data received for keyCode \(keyCode)")
            if keyCode == 49 {
                XCTAssertEqual(received, " ")
            } else if keyCode == 48 {
                XCTAssertEqual(received, "\t")
            } else {
                XCTAssertTrue(received.hasPrefix("\u{1b}") || received.hasPrefix("\r") || received.hasPrefix("\u{7f}"), "Unexpected sequence for keyCode \(keyCode): \(received.debugDescription)")
            }
        }

        delegate.inputDataReceived.removeAll()
        let shiftUp = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: true,
            keyCode: 126
        )!
        view.keyDown(with: shiftUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        delegate.inputDataReceived.removeAll()
        let cmdA = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        view.keyDown(with: cmdA)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Command-modified keys must not send direct PTY bytes")

        delegate.inputDataReceived.removeAll()
        let emptyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        )!
        view.keyDown(with: emptyEvent)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    func testTypingWhileScrolledUpRevealsLiveScreen() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let lines = (0..<50).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        view.scrollViewportUp(lines: 10)
        XCTAssertGreaterThan(view.viewportOffset, 0)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )!
        view.keyDown(with: event)
        XCTAssertEqual(view.viewportOffset, 0, "Typing must reveal live screen")
    }

    // MARK: - 10. Mouse Events & Reports

}
