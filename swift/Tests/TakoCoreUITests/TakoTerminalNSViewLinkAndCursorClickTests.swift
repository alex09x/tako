/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `link-url` (Command-hover underlines and Command-click opens a detected
/// URL or OSC 8 hyperlink) and `cursor-click-to-move` (a plain click on the
/// cursor's own prompt line walks the cursor there with arrow keys).
@MainActor
final class TakoTerminalNSViewLinkAndCursorClickTests: XCTestCase {
    func makeView() -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
        view.layoutSubtreeIfNeeded()
        return view
    }

    func point(forColumn col: Int, row: Int = 0, in view: TakoTerminalNSView) -> NSPoint {
        let origin = view.cellOrigin(row: row, col: col)
        return NSPoint(x: origin.x + max(view.cellWidth, 1) / 2,
                       y: origin.y + max(view.cellHeight, 1) / 2)
    }

    func mouseEvent(
        _ type: NSEvent.EventType, column: Int, row: Int = 0, in view: TakoTerminalNSView,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point(forColumn: column, row: row, in: view),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    func withOpener(_ opener: @escaping (URL) -> Void, _ body: () -> Void) {
        let previous = TakoTerminalNSView.openURL
        TakoTerminalNSView.openURL = opener
        defer { TakoTerminalNSView.openURL = previous }
        body()
    }

    func withConfirmOpenURL(
        _ hook: @escaping (URL, TakoTerminalNSView.LinkSecurityWarning, NSWindow?, @escaping (Bool) -> Void) -> Void,
        _ body: () -> Void
    ) {
        let previous = TakoTerminalNSView.confirmOpenURL
        TakoTerminalNSView.confirmOpenURL = hook
        defer { TakoTerminalNSView.confirmOpenURL = previous }
        body()
    }

    // MARK: - link-url: plain-text URL detection

    func testCommandClickOnAPlainURLOpensIt() {
        let view = makeView()
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: []))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 10, in: view, modifiers: [.command]))
        }
        XCTAssertEqual(opened, [URL(string: "https://example.com/path")!])
    }

    func testCommandHoverOverAURLUnderlinesItAndSetsThePointingHandCursor() {
        let view = makeView()
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: [.command]))
        XCTAssertEqual(view.hoveredLink?.url, URL(string: "https://example.com/path")!)

        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: []))
        XCTAssertNil(view.hoveredLink, "releasing Command must clear the hover")
    }

    /// The bug this pins: deleting the flag check would make every URL
    /// clickable, which the disabled test below would silently pass through.
    func testLinkURLDisabledLeavesPlainURLsUnclickable() {
        let view = makeView()
        view.linkURLDetectionEnabled = false
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 10, in: view, modifiers: [.command]))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testCommandClickWithoutAURLStartsNoOpener() {
        let view = makeView()
        view.feed(data: Data("no links here".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 2, in: view, modifiers: [.command]))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - link-url: OSC 8 hyperlinks keep working regardless of the flag

    func testCommandClickOnAnOSC8HyperlinkOpensItsURI() {
        let view = makeView()
        view.linkURLDetectionEnabled = false
        view.feed(data: Data("\u{1b}]8;;http://osc8.example\u{7}click me\u{1b}]8;;\u{7}".utf8))
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 2, in: view, modifiers: []))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 2, in: view, modifiers: [.command]))
        }
        XCTAssertEqual(opened, [URL(string: "http://osc8.example")!])
    }

    // MARK: - E8: Safer hyperlinks

    func testOSC8LinkHoverShowsRealTargetAndTooltipAndHUD() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]8;;https://example.org/destination\u{7}Documentation\u{1b}]8;;\u{7}".utf8))

        // Hover over the link without Command held
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 2, in: view, modifiers: []))
        XCTAssertEqual(view.hoveredLinkTarget, "https://example.org/destination")
        XCTAssertEqual(view.toolTip, "https://example.org/destination")
        XCTAssertEqual(view.currentHoveredLink?.url.absoluteString, "https://example.org/destination")
        XCTAssertEqual(view.currentHoveredLink?.text, "Documentation")
        XCTAssertFalse(view.currentHoveredLink?.isMismatch ?? true)
        XCTAssertTrue(view.currentHoveredLink?.isSchemeAllowedWithoutPrompt ?? false)
        XCTAssertEqual(delegate.hoveredLinks.last, "https://example.org/destination")

        // Hover off the link
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 40, in: view, modifiers: []))
        XCTAssertNil(view.hoveredLinkTarget)
        XCTAssertNil(view.toolTip)
        XCTAssertNil(view.currentHoveredLink)
        XCTAssertNil(delegate.hoveredLinks.last!)
    }

    func testSafeSchemesOpenWithoutConfirmationPrompt() {
        let view = makeView()
        let safeURLs = [
            "https://example.com/secure",
            "http://example.com/insecure",
            "file:///Users/alex/test.txt"
        ]

        for urlString in safeURLs {
            view.feed(data: Data("\u{1b}[2J\u{1b}[H".utf8))
            view.feed(data: Data("\u{1b}]8;;\(urlString)\u{7}Link\u{1b}]8;;\u{7}".utf8))
            let link = view.linkRange(at: (row: 0, col: 1))
            XCTAssertNotNil(link)
            XCTAssertTrue(link?.isSchemeAllowedWithoutPrompt ?? false)

            // Hover to present preview first
            view.mouseMoved(with: mouseEvent(.mouseMoved, column: 1, in: view, modifiers: []))
            XCTAssertTrue(view.hasPresentedMatchingPreview)

            var opened: [URL] = []
            var promptTriggered = false
            withConfirmOpenURL({ _, _, _, completion in
                promptTriggered = true
                completion(true)
            }) {
                withOpener({ opened.append($0) }) {
                    view.mouseDown(with: mouseEvent(.leftMouseDown, column: 1, in: view, modifiers: [.command]))
                }
            }

            XCTAssertFalse(promptTriggered, "Safe scheme \(urlString) with prior preview must not prompt for confirmation")
            XCTAssertEqual(opened, [URL(string: urlString)!])
        }
    }

    func testCommandClickWithoutPriorHoverPromptsConfirmation() {
        let view = makeView()
        let urlString = "https://example.com/direct-click"
        view.feed(data: Data("\u{1b}[2J\u{1b}[H".utf8))
        view.feed(data: Data("\u{1b}]8;;\(urlString)\u{7}Link\u{1b}]8;;\u{7}".utf8))

        XCTAssertFalse(view.hasPresentedMatchingPreview)

        var opened: [URL] = []
        var observedWarning: TakoTerminalNSView.LinkSecurityWarning?

        // 1. When user declines, link is not opened
        withConfirmOpenURL({ _, warning, _, completion in
            observedWarning = warning
            completion(false)
        }) {
            withOpener({ opened.append($0) }) {
                view.mouseDown(with: mouseEvent(.leftMouseDown, column: 1, in: view, modifiers: [.command]))
            }
        }

        XCTAssertNotNil(observedWarning)
        if case .unconfirmedDestination(let url) = observedWarning {
            XCTAssertEqual(url, URL(string: urlString)!)
        } else {
            XCTFail("Expected unconfirmedDestination warning but got \(String(describing: observedWarning))")
        }
        XCTAssertTrue(opened.isEmpty)

        // 2. When user accepts, link is opened
        withConfirmOpenURL({ _, _, _, completion in
            completion(true)
        }) {
            withOpener({ opened.append($0) }) {
                view.mouseDown(with: mouseEvent(.leftMouseDown, column: 1, in: view, modifiers: [.command]))
            }
        }
        XCTAssertEqual(opened, [URL(string: urlString)!])
    }

    func testUnsafeSchemesRequireConfirmationPrompt() {

}
