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
import Foundation
import Testing
@testable import Tako

/// The layout journal's restore -- every tab shown, joined, the selected one
/// selected, hidden workspaces put away -- gives each pane its focus back
/// under the same UUID without reading it. Only a real focus reads.
@Suite(.serialized)
@MainActor
struct JournalRestoreKeepsUnreadTests {
    private var store: WorkspaceStore { .shared }

    private func unread(_ id: UUID, _ tag: String) {
        NotificationStore.shared.addNotification(id: "journal-\(tag)-\(id)", surfaceId: id,
                                                 paneTitle: tag, title: "done", body: "")
    }

    private func count(_ id: UUID) -> Int { NotificationStore.shared.unreadCount(for: id) }

    private func attach(_ controller: TerminalController) -> NSWindow? {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        controller.windowDidLoad()
        return window
    }

    /// The last run: three tabs of one window, the first selected; the
    /// third in a workspace that is not active. Their windows are gone, the
    /// workspaces' records and the panes' unread notifications stay.
    private func lastRun(hidden: UUID) -> (journal: LayoutJournal.Journal, panes: [UUID], tabs: [String]) {
        let encoder = JSONEncoder()
        var tabs: [Any] = [], panes: [UUID] = [], ids: [String] = []
        for index in 0..<3 {
            let (controller, window) = TerminalTestSupport.loaded()
            let tab = "journal-tab-\(index)-\(UUID().uuidString)"
            window.stableTabIdentifier = tab
            let pane = controller.focusedSurface!
            let state = TerminalRestorableState(from: controller)
            tabs.append(try! JSONSerialization.jsonObject(with: encoder.encode(state)))
            panes.append(pane.id)
            ids.append(tab)
            pane.pty?.terminate()
            Tako.CustomTabGroup.close(window)
            window.orderOut(nil)
            store.assignTab(tabIdentifier: tab, to: index == 2 ? hidden : store.activeWorkspaceId)
        }
        let journal = LayoutJournal.Journal(generation: 1, windows: [
            LayoutJournal.Window(frame: NSRect(x: 120, y: 120, width: 600, height: 400),
                                 isKey: true, selectedTab: 0, tabs: tabs),
        ])
        return (journal, panes, ids)
    }

    @Test func aJournalRestoreLeavesUnseenTabsUnreadAndARealFocusReadsThem() throws {
        TerminalTestSupport.preventQuitting()
        let hidden = store.createWorkspace(name: "journal-hidden-\(UUID().uuidString.prefix(6))").id
        let (journal, panes, tabs) = lastRun(hidden: hidden)
        panes.enumerated().forEach { unread($1, "tab\($0)") }
        let original = LayoutRecorder.presentation
        LayoutRecorder.presentation = .init(loadWindow: attach, activate: {})
        var restored: [TerminalController] = []
        defer {
            LayoutRecorder.presentation = original
            for c in restored {
                c.surfaceTree.forEach { $0.pty?.terminate() }
                if let w = c.window { Tako.CustomTabGroup.close(w); w.orderOut(nil) }
            }
            tabs.forEach { store.removeTab(tabIdentifier: $0) }
            store.deleteWorkspace(id: hidden)
            panes.forEach { NotificationStore.shared.markRead(surfaceId: $0) }
        }

        #expect(panes.map(count) == [1, 1, 1], "the last run left each pane one unread notification")
        LayoutRecorder.restore(journal, app: Tako.App())
        restored = tabs.compactMap { tab in TerminalController.all.first { $0.window?.stableTabIdentifier == tab } }
        // The canvases lay out and hand each pane its pending focus.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(restored.allSatisfy { $0.window?.isKeyWindow != true }, "the test host shows no key window")

        #expect(restored.count == 3, "every tab is back under its saved identifier")
        for (index, controller) in restored.enumerated() {
            #expect(controller.focusedSurface?.id == panes[index], "tab \(index): its pane, same UUID, logically focused")
        }
        #expect(count(panes[1]) == 1, "a tab behind the selected one is not read by being restored")
        #expect(count(panes[2]) == 1, "nor a tab of a workspace that is not shown")
        #expect(count(panes[0]) == 1, "nor the selected one, while its window is not key")

        // The positive case: its window key, the user really looks at the pane
        // (`syncFocusToSurfaceTree` on becoming key).
        try #require(restored.count == 3)
        let pane = try #require(restored[1].focusedSurface)
        pane.focusDidChange(true)
        #expect(count(panes[1]) == 0, "a real focus reads the pane")
    }

    /// New Tab loads its window inside an unseen scope; loading must not end that scope early.
    @Test func anUnseenFocusInsideAnotherKeepsTheOuterGuard() throws {
        TerminalTestSupport.preventQuitting()
        let (controller, window) = TerminalTestSupport.loaded()
        defer { TerminalTestSupport.tearDown(controller, window) }
        let pane = try #require(controller.focusedSurface)
        controller.focusChangeMarksSeen = false
        controller.setFocusedSurfaceUnseen(nil)
        controller.setFocusedSurfaceUnseen(pane)
        #expect(controller.focusChangeMarksSeen == false, "the inner call released the outer scope's guard")
        controller.focusChangeMarksSeen = true
        controller.setFocusedSurfaceUnseen(nil)
        #expect(controller.focusChangeMarksSeen == true, "outside any scope the guard is back on")
    }
}
