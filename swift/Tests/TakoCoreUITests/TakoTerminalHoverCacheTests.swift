// Tako — hover lookup correctness and bounded work across unchanged rows
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
private final class HoverPointerWindow: NSWindow {
    var pointer = NSPoint.zero
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
}

@MainActor
final class TakoTerminalHoverCacheTests: XCTestCase {
    private func view(_ text: String) -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
        view.layoutSubtreeIfNeeded()
        view.feed(data: Data(text.utf8))
        return view
    }

    private func point(_ column: Int, row: Int = 0, in view: TakoTerminalNSView) -> NSPoint {
        let origin = view.cellOrigin(row: row, col: column)
        return NSPoint(x: origin.x + view.cellWidth / 2, y: origin.y + view.cellHeight / 2)
    }

    private func move(_ column: Int, row: Int = 0, in view: TakoTerminalNSView,
                      modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: point(column, row: row, in: view),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        view.mouseMoved(with: event)
    }

    func testManyMouseEventsOnOneRowDecodeItOnlyOnce() {
        let terminal = view("plain https://first.test x https://second.test")
        let start = terminal.hoverLinkRowReadCount
        for index in 0..<800 { move(index % 45, in: terminal) }
        XCTAssertEqual(terminal.hoverLinkRowReadCount - start, 1)
        move(10, in: terminal, modifiers: [.command])
        XCTAssertEqual(terminal.hoveredLink?.url.absoluteString, "https://first.test")
        move(32, in: terminal)
        XCTAssertEqual(terminal.currentHoveredLink?.url.absoluteString, "https://second.test")
        XCTAssertNil(terminal.hoveredLink, "Releasing Command must still remove the underline")
        move(0, in: terminal)
        XCTAssertNil(terminal.currentHoveredLink)
        XCTAssertEqual(terminal.hoverLinkRowReadCount - start, 1)
    }

    func testChangedRowRechecksAndUnchangedRowKeepsItsCachedResult() {
        let terminal = view("https://before.test")
        move(5, in: terminal)
        let before = terminal.hoverLinkRowReadCount
        terminal.invalidateHoverLinkRow(changedRows: IndexSet(integer: 1))
        move(5, in: terminal)
        XCTAssertEqual(terminal.hoverLinkRowReadCount, before)
        terminal.core.feed(bytes: Data("\u{1b}[H\u{1b}[2Khttps://after.test".utf8))
        terminal.invalidateHoverLinkRow(changedRows: IndexSet(integer: 0))
        move(5, in: terminal)
        XCTAssertEqual(terminal.currentHoveredLink?.url.absoluteString, "https://after.test")
        XCTAssertEqual(terminal.hoverLinkRowReadCount, before + 1)
    }

    func testPolicyChangeAndWideTextKeepColumnMappingCorrect() {
        let terminal = view("界界 https://wide.test")
        move(7, in: terminal)
        XCTAssertEqual(terminal.currentHoveredLink?.url.absoluteString, "https://wide.test")
        terminal.linkURLDetectionEnabled = false
        let before = terminal.hoverLinkRowReadCount
        move(7, in: terminal)
        XCTAssertNil(terminal.currentHoveredLink)
        XCTAssertEqual(terminal.hoverLinkRowReadCount, before)
        terminal.linkURLDetectionEnabled = true
        move(7, in: terminal)
        XCTAssertEqual(terminal.currentHoveredLink?.url.absoluteString, "https://wide.test")
    }

    func testCommandClickUsesTheCurrentOSC8TargetAfterCachedHover() {
        let terminal = view("\u{1b}]8;;https://before.test\u{7}Link\u{1b}]8;;\u{7}")
        move(1, in: terminal)
        XCTAssertEqual(terminal.currentHoveredLink?.url.absoluteString, "https://before.test")
        terminal.core.feed(bytes: Data("\u{1b}[H\u{1b}]8;;https://after.test\u{7}Link\u{1b}]8;;\u{7}".utf8))
        let oldOpener = TakoTerminalNSView.openURL
        let oldConfirmation = TakoTerminalNSView.confirmOpenURL
        defer {
            TakoTerminalNSView.openURL = oldOpener
            TakoTerminalNSView.confirmOpenURL = oldConfirmation
        }
        var opened: [URL] = []
        var confirmed = false
        TakoTerminalNSView.openURL = { opened.append($0) }
        TakoTerminalNSView.confirmOpenURL = { _, _, _, completion in confirmed = true; completion(true) }
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point(1, in: terminal),
            modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        terminal.mouseDown(with: event)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://after.test"])
        XCTAssertTrue(confirmed, "A changed target must not inherit the old preview's approval")
    }

    func testWrappedOSC8TextIsInvalidatedByNeighbouringRowDamage() {
        let terminal = view("")
        let window = HoverPointerWindow(contentRect: terminal.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = terminal
        defer { window.contentView = nil; window.orderOut(nil) }
        terminal.layoutSubtreeIfNeeded()
        let prefix = String(repeating: "a", count: terminal.cols)
        terminal.feed(data: Data("\u{1b}]8;;https://target.test\u{7}\(prefix)before\u{1b}]8;;\u{7}".utf8))
        window.pointer = point(1, in: terminal)
        move(1, in: terminal)
        XCTAssertTrue(terminal.currentHoveredLink?.text.hasSuffix("before") == true)
        XCTAssertNotNil(terminal.hoverLinkRowCache)
        terminal.core.feed(bytes: Data("\u{1b}[2;1H\u{1b}[2K\u{1b}]8;;https://target.test\u{7}after\u{1b}]8;;\u{7}".utf8))
        terminal.refreshHoveredLinkAfterFrame(changedRows: IndexSet(integer: 1))
        XCTAssertTrue(terminal.currentHoveredLink?.text.hasSuffix("after") == true,
                      "Damage on a wrapped neighbour must refresh the displayed OSC 8 security text")
        terminal.clearHoveredLink()
        XCTAssertNil(terminal.hoverLinkRowCache)
        XCTAssertNil(terminal.lastFrameHoverCell)
    }

    func testProfileEquivalentRowLookupWorkload() {
        let terminal = view(String(repeating: "text ", count: 10) + "https://example.test/path")
        let points = (0..<500).map { point($0 % 70, in: terminal) }
        let beforeCount = terminal.hoverLinkRowReadCount
        let beforeStart = ProcessInfo.processInfo.systemUptime
        for point in points { terminal.refreshHoveredLink(at: point, commandHeld: false) }
        let beforeMS = (ProcessInfo.processInfo.systemUptime - beforeStart) * 1000
        let beforeReads = terminal.hoverLinkRowReadCount - beforeCount
        terminal.clearHoveredLink()
        let afterCount = terminal.hoverLinkRowReadCount
        let afterStart = ProcessInfo.processInfo.systemUptime
        for index in 0..<500 { move(index % 70, in: terminal) }
        let afterMS = (ProcessInfo.processInfo.systemUptime - afterStart) * 1000
        let afterReads = terminal.hoverLinkRowReadCount - afterCount
        print("HOVER_WORKLOAD uncached_ms=\(beforeMS) cached_ms=\(afterMS) uncached_row_reads=\(beforeReads) cached_row_reads=\(afterReads)")
        XCTAssertEqual(beforeReads, 500)
        XCTAssertEqual(afterReads, 1)
    }
}
#endif
