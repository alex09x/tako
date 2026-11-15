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

/// Loading or restoring a window gives each tab its focused pane back, but
/// only logically: a pane's unread notifications stay until the user really
/// focuses it. Restoring after a relaunch must not read what nobody saw.
@Suite(.serialized)
@MainActor
struct RestoreKeepsUnreadTests {
    private func unread(_ surface: Tako.SurfaceView, _ tag: String) {
        NotificationStore.shared.addNotification(id: "restore-\(tag)-\(surface.id)", surfaceId: surface.id,
                                                 paneTitle: tag, title: "done", body: "")
    }

    private func count(_ surface: Tako.SurfaceView) -> Int {
        NotificationStore.shared.unreadCount(for: surface.id)
    }

    private func newWindow() -> TerminalWindow {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func loadingAWindowLeavesItsOnlyPaneUnread() {
        TerminalTestSupport.preventQuitting()
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        unread(view, "load")
        defer { NotificationStore.shared.markRead(surfaceId: view.id) }
        let (controller, window) = TerminalTestSupport.makeController(surfaceTree: .init(view: view))
        defer { TerminalTestSupport.tearDown(controller, window) }

        controller.windowDidLoad()

        #expect(controller.focusedSurface === view, "its logical focus")
        #expect(count(view) == 1, "loading a window is not looking at it")
    }

    @Test func appKitRestorationLeavesTheFocusedPaneUnread() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }
        TerminalTestSupport.preventQuitting()

        // The restored tree reuses the original view, so the saved focus
        // matches it by identity (see TerminalRestorableCoverageTests).
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let source = TerminalController(appDelegate.tako, withSurfaceTree: .init(view: view))
        source.focusedSurface = view
        let state = TerminalRestorableState(from: source)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        unread(view, "appkit")
        defer { NotificationStore.shared.markRead(surfaceId: view.id) }

        var restored: TerminalController?
        let original = TerminalWindowRestoration.system
        TerminalWindowRestoration.system = .init(makeController: { app, _, tabIdentifier in
            let controller = TerminalController(app, withSurfaceTree: .init(view: view))
            controller.restoredTabIdentifier = tabIdentifier
            let window = newWindow()
            controller.window = window
            controller.windowDidLoad()
            restored = controller
            return (controller, window)
        })
        defer { TerminalWindowRestoration.system = original }

        var window: NSWindow?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: unarchiver
        ) { result, _ in window = result }
        unarchiver.finishDecoding()
        defer { window?.orderOut(nil) }

        #expect(window != nil)
        #expect(restored?.focusedSurface === view, "the saved focus is back")
        #expect(count(view) == 1, "a restored tab nobody looked at keeps its unread")
    }

    @Test func regroupingLeavesHiddenTabsUnreadAndARealFocusReadsThem() throws {
        TerminalTestSupport.preventQuitting()
        let app = Tako.App()
        var controllers: [TerminalController] = []
        var views: [Tako.SurfaceView] = []
        for _ in 0..<2 {
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            let controller = TerminalController(app, withSurfaceTree: .init(view: view))
            controller.window = newWindow()
            controller.setFocusedSurfaceUnseen(view)
            controllers.append(controller)
            views.append(view)
        }
        defer {
            for c in controllers {
                if let w = c.window { Tako.CustomTabGroup.leave(w); w.orderOut(nil) }
            }
            views.forEach { NotificationStore.shared.markRead(surfaceId: $0.id) }
        }
        // The journal the last run wrote: both tabs with their canvas, the
        // first selected; the second tab is hidden behind it.
        let encoder = JSONEncoder()
        let tabs: [Any] = try controllers.map {
            let state = TerminalRestorableState(from: $0)
            #expect(state.floatingCanvas != nil, "the regroup path restores focus only with a canvas snapshot")
            return try JSONSerialization.jsonObject(with: encoder.encode(state))
        }
        for c in controllers { c.setFocusedSurfaceUnseen(nil) }
        views.enumerated().forEach { unread($1, "regroup-\($0)") }

        LayoutRecorder.regroup(LayoutJournal.Journal(generation: 1, windows: [
            LayoutJournal.Window(frame: NSRect(x: 100, y: 100, width: 500, height: 300),
                                 isKey: false, selectedTab: 0, tabs: tabs),
        ]))

        #expect(controllers[1].focusedSurface === views[1], "the hidden tab's saved focus is back")
        #expect(count(views[1]) == 1, "a hidden tab is not read by being restored")
        #expect(count(views[0]) == 1, "nor is the selected one before the user focuses it")

        // The positive case: the user really focuses the pane.
        views[1].didGainSurfaceFocus(flushTitle: false)
        #expect(count(views[1]) == 0, "a real focus reads the pane")
    }
}
