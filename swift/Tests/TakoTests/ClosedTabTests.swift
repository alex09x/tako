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

/// A tab that closed stays closed. A script ran `exit` in three tabs and
/// then `takoctl close` on each, then switched workspaces: three empty
/// windows came back on screen over the real one, with no tab bar, no
/// sidebar and no terminal. Asking about a closed window made it a group
/// of its own again, listed its tab in the active workspace, and the
/// workspace switch put every group's chosen window in front.
@Suite(.serialized) @MainActor
struct ClosedTabTests {
    private final class Answer: @unchecked Sendable { var value: ControlResponse? }

    init() {
        // Same bootstrap as loaded(): shared test stores must be in-memory
        // before a private controller can ask for its workspace.
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
    }

    /// Two private non-interactive terminals; the second exits, then its tab
    /// is explicitly closed. A child exit alone keeps an empty canvas session.
    private func exitedTab() throws -> (kept: NSWindow, closed: NSWindow, surface: Tako.SurfaceView, all: [AnyObject]) {
        TerminalTestSupport.preventQuitting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tako-closed-tab-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var handedOff = false
        var owned: [(TerminalController, NSWindow)] = []
        defer {
            if !handedOff {
                for (owner, window) in owned { TerminalTestSupport.tearDown(owner, window) }
                try? FileManager.default.removeItem(at: root)
            }
        }
        let config = root.appendingPathComponent("config")
        try "session-persistence = false\nwindow-save-state = never\nauto-update = off\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let app = Tako.App(configPath: config.path)
        var base = Tako.SurfaceConfiguration(workingDirectory: root.path, environmentVariables: [
            "HOME": root.path, "XDG_CONFIG_HOME": root.path, "XDG_DATA_HOME": root.path,
            "XDG_CACHE_HOME": root.path, "HISTFILE": root.appendingPathComponent("history").path,
            "ZDOTDIR": root.path, "TAKO_AGENT_HOOKS_HOME": root.path, "CODEX_HOME": root.path,
        ])
        base.program = ["/bin/sleep", "60"]
        base.allowsSessionPersistence = false
        func terminal() -> (TerminalController, TerminalWindow) {
            let owner = TerminalController(app, withBaseConfig: base)
            let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                        backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            owner.window = window
            owner.windowDidLoad()
            return (owner, window)
        }
        let (a, aWindow) = terminal()
        owned.append((a, aWindow))
        let (b, bWindow) = terminal()
        owned.append((b, bWindow))
        Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
        let surface = try #require(b.surfaceTree.first)
        // What a shell that exits on its own does.
        surface.pty?.terminate()
        NotificationCenter.default.post(
            name: Tako.Notification.takoCloseSurface, object: surface, userInfo: ["process_alive": false])
        #expect(b.surfaceTree.isEmpty, "the child exit leaves an empty session")
        #expect(!Tako.CustomTabGroup.isClosed(bWindow), "the empty canvas stays until the tab is closed")
        b.closeTabImmediately(registerRedo: false)
        handedOff = true
        return (aWindow, bWindow, surface, [a, b, aWindow, bWindow, root as NSURL])
    }

    private func finish(_ all: [AnyObject], surface: Tako.SurfaceView) {
        surface.pty?.terminate()
        for (controller, window) in zip(all.compactMap({ $0 as? TerminalController }),
                                        all.compactMap({ $0 as? NSWindow })) {
            TerminalTestSupport.tearDown(controller, window)
        }
        for root in all.compactMap({ $0 as? NSURL }) {
            try? FileManager.default.removeItem(at: root as URL)
        }
    }

    private func isListed(_ window: NSWindow) -> Bool {
        Tako.CustomTabGroup.existingGroup(for: window) != nil
            || Tako.CustomTabGroup.allGroups.contains { $0.windows.contains(window) }
    }

    @Test func aTabClosedAfterItsChildExitsLeavesItsWindowAndItsWorkspace() throws {
        let (kept, closed, surface, all) = try exitedTab()
        defer { finish(all, surface: surface) }
        #expect(!closed.isVisible)
        #expect(!isListed(closed))
        #expect(WorkspaceStore.shared.workspace(forTab: closed.stableTabIdentifier) == nil)
        #expect(Tako.CustomTabGroup.group(for: kept).windows == [kept])
    }

    @Test func askingAboutAClosedTabDoesNotBringItBack() throws {
        let (_, closed, surface, all) = try exitedTab()
        defer { finish(all, surface: surface) }
        let group = Tako.CustomTabGroup.group(for: closed)
        #expect(group.windows == [closed])
        #expect(!isListed(closed))
        #expect(WorkspaceStore.shared.workspace(forTab: closed.stableTabIdentifier) == nil)
    }

    /// With no window main, new tabs and app actions go to the last main
    /// one -- never to a closed tab's.
    @Test func aClosedTabIsNoParentForNewTabs() throws {
        let (_, closed, surface, all) = try exitedTab()
        defer { finish(all, surface: surface); TerminalController.lastMain = nil }
        let gone = try #require(closed.windowController as? TerminalController)
        TerminalController.lastMain = gone
        #expect(TerminalController.preferredParent !== gone)
    }

    /// What the script did: `takoctl close` on the tab whose shell is
    /// gone, then a workspace switch, with windows really ordered.
    @Test func closingItAgainAndSwitchingWorkspacesLeavesItClosed() throws {
        // Initialize the shared store in test mode before opting into ordering.
        _ = WorkspaceStore.shared
        let ordering = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = false
        defer { Tako.CustomTabGroup.suppressWindowOrderingForTesting = ordering }
        let (kept, closed, surface, all) = try exitedTab()
        defer { finish(all, surface: surface) }

        // `takoctl close` looks the pane up among these; there is none.
        let pane = ControlCommands.panes().first { $0.surface === surface }
        #expect(pane == nil, "takoctl still names the closed tab's pane")
        if let pane {
            let answer = Answer()
            ControlLayout.close(pane.surface) { answer.value = $0 }
            TerminalTestSupport.waitUntil(timeout: 1) { answer.value != nil }
        }
        // What a workspace switch does to every group: puts its chosen window
        // in front. Only to the groups holding this test's windows -- the
        // whole switch, or every group, would bring other tests' windows up
        // and leave one key for the next test to inherit.
        for group in Tako.CustomTabGroup.allGroups where group.windows.contains(where: { $0 === kept || $0 === closed }) {
            group.syncWithActiveWorkspace()
        }

        #expect(!closed.isVisible)
        #expect(!isListed(closed))
        #expect(WorkspaceStore.shared.workspace(forTab: closed.stableTabIdentifier) == nil)
    }
}
