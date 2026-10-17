/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import XCTest
@testable import TakoCoreUI

extension TakoTerminalNSView {
    /// Whether the view has its own right/middle button handlers, so a test
    /// can stop before a click would fall through to a real, modal menu.
    static var overridesRightAndMiddleButtons: Bool {
        [#selector(NSView.rightMouseDown(with:)), #selector(NSView.rightMouseUp(with:)),
         #selector(NSView.otherMouseDown(with:)), #selector(NSView.otherMouseUp(with:))].allSatisfy {
            TakoTerminalNSView.instanceMethod(for: $0) != NSView.instanceMethod(for: $0)
        }
    }
}

/// Right and middle clicks go to a program that asked for mouse reports;
/// otherwise the right button opens the context menu, through a seam no
/// test lets reach a real menu loop.
@MainActor
final class TakoTerminalNSViewOtherButtonsTests: XCTestCase {
    private var shownMenus: [NSMenu] = []
    private var realPresenter: ((NSMenu, NSEvent, NSView) -> Void)!

    override func setUp() {
        super.setUp()
        realPresenter = TakoTerminalNSView.presentContextMenu
        TakoTerminalNSView.presentContextMenu = { [weak self] menu, _, _ in
            MainActor.assumeIsolated { self?.shownMenus.append(menu) }
        }
    }

    override func tearDown() {
        TakoTerminalNSView.presentContextMenu = realPresenter
        super.tearDown()
    }

    private func click(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testTheViewHandlesItsOwnRightAndMiddleButtons() {
        XCTAssertTrue(TakoTerminalNSView.overridesRightAndMiddleButtons)
    }

    func testAProgramThatAskedForMouseReportsGetsRightAndMiddleClicksNotAMenu() {
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))

        view.rightMouseDown(with: click(.rightMouseDown))
        XCTAssertTrue(String(decoding: delegate.inputDataReceived, as: UTF8.self).hasPrefix("\u{1b}[<2;"),
                      "SGR report for the right button")
        delegate.inputDataReceived = Data()
        view.otherMouseDown(with: click(.otherMouseDown))
        XCTAssertTrue(String(decoding: delegate.inputDataReceived, as: UTF8.self).hasPrefix("\u{1b}[<1;"),
                      "SGR report for the middle button")
        XCTAssertTrue(shownMenus.isEmpty)
    }

    func testWithoutMouseReportsTheRightButtonOpensTheMenu() {
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.rightMouseDown(with: click(.rightMouseDown))
        XCTAssertEqual(shownMenus.count, 1)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }
}
