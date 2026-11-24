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

/// A relaunch that changes nothing leaves the workspaces' tab records as
/// they were. Loading a window already lists and draws its tab -- the
/// `pane_focused` event names its window, the sidebar asks for its filter --
/// and the first ask files the tab under its workspace. A restored window
/// has its saved identifier from the start, so no passing one is filed.
@Suite(.serialized)
@MainActor
struct RestoreKeepsTabIdentityTests {
    private var store: WorkspaceStore { .shared }

    private func newWindow() -> TerminalWindow {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    /// The stored tabs of every workspace, in their order.
    private func stored() -> [[String]] { store.workspaces.map(\.tabIdentifiers) }

    private func added(since before: [[String]]) -> Set<String> {
        Set(stored().flatMap { $0 }).subtracting(before.flatMap { $0 })
    }

    /// The last run's tab, stored in the active workspace; its window gone, as after a quit.
    private func savedTab() -> (state: TerminalRestorableState, id: String) {
        let (source, window) = TerminalTestSupport.loaded()
        let saved = "restore-identity-\(UUID().uuidString)"
        window.stableTabIdentifier = saved
        let state = TerminalRestorableState(from: source)
        Tako.CustomTabGroup.close(window)
        window.orderOut(nil)
        store.assignTab(tabIdentifier: saved, to: store.activeWorkspaceId)
        return (state, saved)
    }

    /// One AppKit restoration of `state`, as at a relaunch. The test host has
    /// no nib, so the window is attached by hand -- as the real
    /// `makeController` does, with the saved identifier before it loads.
    private func restoreOnce(_ state: TerminalRestorableState) throws -> NSWindow {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        state.encode(with: archiver)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        unarchiver.requiresSecureCoding = true
        let original = TerminalWindowRestoration.system
        TerminalWindowRestoration.system = .init(makeController: { app, tree, tabIdentifier in
            let controller = TerminalController(app, withSurfaceTree: tree)
            controller.restoredTabIdentifier = tabIdentifier
            let window = newWindow()
            controller.window = window
            controller.windowDidLoad()
            return (controller, window)
        })
        defer { TerminalWindowRestoration.system = original }
        var restored: NSWindow?
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: unarchiver
        ) { window, _ in restored = window }
        unarchiver.finishDecoding()
        return try #require(restored)
    }

    @Test func twoNoOpAppKitRelaunchesKeepTheStoredTabsAndTheirOrder() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }
        TerminalTestSupport.preventQuitting()
        let (state, saved) = savedTab()
        let before = stored()
        var windows: [NSWindow] = []
        defer {
            windows.forEach { Tako.CustomTabGroup.close($0); $0.orderOut(nil) }
            store.removeTab(tabIdentifier: saved)
        }

        for cycle in 1...2 {
            let window = try restoreOnce(state)
            windows.append(window)
            _ = Tako.CustomTabGroup.group(for: window)
            #expect(window.stableTabIdentifier == saved, "cycle \(cycle): the tab is back under its saved identifier")
            #expect(stored() == before, "cycle \(cycle): stored tabs changed, added \(added(since: before))")
            window.orderOut(nil)
        }
    }

    /// The layout journal's order: the controller is given the saved
    /// identifier, its window loads, then joins its group.
    @Test func twoNoOpJournalRestoresKeepTheStoredTabsAndTheirOrder() throws {
        TerminalTestSupport.preventQuitting()
        let (state, saved) = savedTab()
        let before = stored()
        var windows: [NSWindow] = []
        defer {
            windows.forEach { Tako.CustomTabGroup.close($0); $0.orderOut(nil) }
            store.removeTab(tabIdentifier: saved)
        }

        for cycle in 1...2 {
            let (controller, window) = TerminalTestSupport.makeController(surfaceTree: state.surfaceTree)
            controller.restoredTabIdentifier = state.tabIdentifier
            controller.windowDidLoad()
            _ = Tako.CustomTabGroup.group(for: window)
            windows.append(window)
            #expect(window.stableTabIdentifier == saved, "cycle \(cycle): the tab is back under its saved identifier")
            #expect(stored() == before, "cycle \(cycle): stored tabs changed, added \(added(since: before))")
            window.orderOut(nil)
        }
    }

    /// A new window, with nothing to restore, still gets an identifier of its own.
    @Test func aNewWindowStillGetsAFreshIdentifier() {
        TerminalTestSupport.preventQuitting()
        let (controller, window) = TerminalTestSupport.makeController()
        defer { Tako.CustomTabGroup.close(window); window.orderOut(nil) }
        #expect(controller.restoredTabIdentifier == nil)
        controller.windowDidLoad()
        #expect(UUID(uuidString: window.stableTabIdentifier) != nil)
    }
}
