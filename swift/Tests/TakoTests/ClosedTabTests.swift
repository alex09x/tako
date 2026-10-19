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

    /// Two tabs in one window; the second one's shell exits.
    private func exitedTab() throws -> (kept: NSWindow, closed: NSWindow, surface: Tako.SurfaceView, all: [AnyObject]) {
        let (a, aWindow) = TerminalTestSupport.loaded()
        let (b, bWindow) = TerminalTestSupport.loaded()
        Tako.CustomTabGroup.join(bWindow, to: aWindow, select: true)
        let surface = try #require(b.surfaceTree.first)
        // What a shell that exits on its own does.
        NotificationCenter.default.post(
            name: Tako.Notification.takoCloseSurface, object: surface, userInfo: ["process_alive": false])
        return (aWindow, bWindow, surface, [a, b, aWindow, bWindow])
    }

    private func isListed(_ window: NSWindow) -> Bool {
        Tako.CustomTabGroup.existingGroup(for: window) != nil
            || Tako.CustomTabGroup.allGroups.contains { $0.windows.contains(window) }
    }

    @Test func anExitedTabLeavesItsWindowAndItsWorkspace() throws {
        let (kept, closed, _, all) = try exitedTab()
        defer { Tako.CustomTabGroup.leave(kept); withExtendedLifetime(all) {} }
        #expect(!closed.isVisible)
        #expect(!isListed(closed))
        #expect(WorkspaceStore.shared.workspace(forTab: closed.stableTabIdentifier) == nil)
        #expect(Tako.CustomTabGroup.group(for: kept).windows == [kept])
    }

    @Test func askingAboutAClosedTabDoesNotBringItBack() throws {
        let (kept, closed, _, all) = try exitedTab()
        defer { Tako.CustomTabGroup.leave(kept); withExtendedLifetime(all) {} }
        let group = Tako.CustomTabGroup.group(for: closed)
        #expect(group.windows == [closed])
        #expect(!isListed(closed))
        #expect(WorkspaceStore.shared.workspace(forTab: closed.stableTabIdentifier) == nil)
    }

    /// With no window main, new tabs and app actions go to the last main
    /// one -- never to a closed tab's.
    @Test func aClosedTabIsNoParentForNewTabs() throws {
        let (kept, closed, _, all) = try exitedTab()
        defer { Tako.CustomTabGroup.leave(kept); TerminalController.lastMain = nil; withExtendedLifetime(all) {} }
        let gone = try #require(closed.windowController as? TerminalController)
        TerminalController.lastMain = gone
        #expect(TerminalController.preferredParent !== gone)
    }

    /// What the script did: `takoctl close` on the tab whose shell is
    /// gone, then a workspace switch, with windows really ordered.
    @Test func closingItAgainAndSwitchingWorkspacesLeavesItClosed() throws {
        let ordering = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = false
        defer { Tako.CustomTabGroup.suppressWindowOrderingForTesting = ordering }
        let (kept, closed, surface, all) = try exitedTab()
        defer { kept.close(); withExtendedLifetime(all) {} }

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
