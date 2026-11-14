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
import Testing
@testable import Tako

/// A double click renames a sidebar row only when both clicks are on that
/// row, in the same sidebar, within the double-click interval. A second click
/// that lands on another row (the rows moved between the clicks) only selects.
@Suite(.serialized) @MainActor
struct SidebarDoubleClickTests {
    typealias Click = SidebarDoubleClick.Click

    @Test func onlyTwoClicksOnTheSameRowInTheSameWindowInTimeMakeADoubleClick() {
        let w1 = NSWindow(), w2 = NSWindow()
        let one = ObjectIdentifier(w1), other = ObjectIdentifier(w2)
        var clicks = SidebarDoubleClick()
        func click(_ row: String, _ place: ObjectIdentifier, _ time: TimeInterval, _ count: Int) -> Bool {
            clicks.isSecond(Click(row: row, place: place, timestamp: time), clickCount: count, interval: 0.5)
        }
        let results = [
            click("A", one, 10, 1), click("A", one, 10.2, 2),     // A then A
            click("A", one, 20, 1), click("B", one, 20.2, 2),     // the second click landed on another row
            click("A", one, 30, 1), click("A", other, 30.2, 2),   // the same row in another physical window
            click("A", one, 40, 1), click("A", one, 40.9, 2),     // too late
        ]
        #expect(results == [false, true, false, false, false, false, false, false])

        clicks = SidebarDoubleClick()
        let noFirst = click("A", one, 50, 2)
        #expect(!noFirst, "a second click with no first one recorded")
    }

    private func event(_ count: Int, at time: TimeInterval, type: NSEvent.EventType = .leftMouseUp) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: count, pressure: 0)
    }

    @Test func aRowRenamesOnItsOwnDoubleClickButNotOnASecondClickMeantForAnother() throws {
        let editor = SidebarRenameEditor.shared
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
        controller.window = window
        window.windowController = controller
        defer { window.close(); editor.cancel(); SidebarRowTitle.clicks = SidebarDoubleClick() }
        let tab = window.stableTabIdentifier
        let a = SessionSidebarItem(id: tab, surfaceId: view.id, index: 0, isSelected: true, title: "fish", tabId: tab)
        let b = SessionSidebarItem(id: "\(tab)-pane-\(view.id)", surfaceId: view.id, index: 0, isSelected: false,
                                   title: "fish", isChild: true, indentationLevel: 2, tabId: tab)
        try #require(SessionSidebarStore.shared.canRename(a, around: window) && SessionSidebarStore.shared.canRename(b, around: window))
        SidebarRowTitle.clicks = SidebarDoubleClick()

        // A, then the rows move and the second click of the pair lands on B.
        SidebarRowTitle.renameIfDoubleClick(a, in: window, event: event(1, at: 100), interval: 0.5)
        SidebarRowTitle.renameIfDoubleClick(b, in: window, event: event(2, at: 100.2), interval: 0.5)
        #expect(editor.edit == nil, "B got one click: it is selected, not renamed")

        // A, A: renames A.
        SidebarRowTitle.renameIfDoubleClick(a, in: window, event: event(1, at: 200), interval: 0.5)
        #expect(editor.edit == nil, "one click never renames")
        SidebarRowTitle.renameIfDoubleClick(a, in: window, event: event(2, at: 200.2), interval: 0.5)
        #expect(editor.isEditing(a.id, in: window))
        #expect(!editor.isEditing(b.id, in: window))
        editor.cancel()

        // An inactive tab's row: the first click shows that tab, whose window
        // (same tab group) has its own sidebar; the second click comes from it.
        let shown = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                             backing: .buffered, defer: false)
        shown.isReleasedWhenClosed = false
        defer { shown.close() }
        Tako.CustomTabGroup.join(shown, to: window, select: false)
        SidebarRowTitle.renameIfDoubleClick(a, in: window, event: event(1, at: 250), interval: 0.5)
        SidebarRowTitle.renameIfDoubleClick(a, in: shown, event: event(2, at: 250.2), interval: 0.5)
        #expect(editor.edit != nil, "both clicks on A, from two sidebars of one physical window")
        editor.cancel()

        // A keyboard or other event behind the action never counts.
        SidebarRowTitle.renameIfDoubleClick(a, in: window, event: nil, interval: 0.5)
        SidebarRowTitle.renameIfDoubleClick(a, in: window, event: event(2, at: 300, type: .rightMouseUp), interval: 0.5)
        #expect(editor.edit == nil)
    }
}
