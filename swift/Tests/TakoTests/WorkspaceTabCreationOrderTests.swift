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

@Suite(.serialized) @MainActor
struct WorkspaceTabCreationOrderTests {
    @Test(arguments: [false, true])
    func newTabAfterTheOnlyVisibleTabKeepsItsParentFirst(select: Bool) throws {
        try withFixture(windowCount: 3) { fixture in
            let (a0, a1, b0) = (fixture.windows[0], fixture.windows[1], fixture.windows[2])
            fixture.arrange(hidden: [a0, a1], active: [b0], physical: [a0, a1, b0])
            let created = try fixture.newTab(from: b0, select: select)

            #expect(fixture.group.windows == [a0, a1, b0, created])
            fixture.expectOrder(active: [b0, created], hidden: [a0, a1])
            fixture.expectSelection(select ? created : b0)
        }
    }

    @Test(arguments: [false, true])
    func newTabBeforeRemainingTabsKeepsBothOrdersWithHiddenInterleaving(select: Bool) throws {
        try withFixture { fixture in
            let (a0, a1, b0, b1, b2) = (
                fixture.windows[0], fixture.windows[1], fixture.windows[2],
                fixture.windows[3], fixture.windows[4])
            fixture.arrange(hidden: [a0, a1], active: [b0, b1, b2], physical: [a0, b0, a1, b1, b2])
            let created = try fixture.newTab(from: b0, select: select)

            #expect(fixture.group.windows == [a0, b0, created, a1, b1, b2])
            fixture.expectOrder(active: [b0, created, b1, b2], hidden: [a0, a1])
            fixture.expectSelection(select ? created : b0)

            // Workspace switching must retain the model order and hidden tabs.
            #expect(fixture.store.switchWorkspace(to: fixture.hiddenWorkspace))
            #expect(fixture.group.visibleWindows == [a0, a1])
            #expect(fixture.store.switchWorkspace(to: fixture.activeWorkspace))
            fixture.expectOrder(active: [b0, created, b1, b2], hidden: [a0, a1])
            fixture.expectSelection(select ? created : b0)
        }
    }

    @Test(arguments: [false, true])
    func newTabFromAnotherWorkspaceBelongsToTheActiveWorkspace(select: Bool) throws {
        try withFixture(windowCount: 2) { fixture in
            let (a0, a1) = (fixture.windows[0], fixture.windows[1])
            fixture.arrange(hidden: [a0, a1], active: [], physical: [a0, a1])
            let created = try fixture.newTab(from: a0, select: select)

            #expect(fixture.group.windows == [a0, created, a1])
            fixture.expectOrder(active: [created], hidden: [a0, a1])
            #expect(fixture.store.workspace(forTab: created.stableTabIdentifier)?.id == fixture.activeWorkspace)
        }
    }

    private func withFixture(windowCount: Int = 5, _ body: (Fixture) throws -> Void) rethrows {
        let ordering = Tako.CustomTabGroup.suppressWindowOrderingForTesting
        let emptyCreation = WorkspaceStore.shared.suppressEmptyWorkspaceCreation
        Tako.CustomTabGroup.resetForTesting()
        Tako.CustomTabGroup.suppressWindowOrderingForTesting = true
        WorkspaceStore.shared.suppressEmptyWorkspaceCreation = true
        WorkspaceStore.shared.resetForTesting()
        let fixture = Fixture(windowCount: windowCount)
        defer {
            for controller in fixture.controllers {
                controller.cancelPendingInitialPresentation()
                if let window = controller.window { Tako.CustomTabGroup.leave(window) }
            }
            Tako.CustomTabGroup.resetForTesting()
            WorkspaceStore.shared.resetForTesting()
            Tako.CustomTabGroup.suppressWindowOrderingForTesting = ordering
            WorkspaceStore.shared.suppressEmptyWorkspaceCreation = emptyCreation
            withExtendedLifetime(fixture) {}
        }
        try body(fixture)
    }

    @MainActor private final class Fixture {
        let store = WorkspaceStore.shared
        let hiddenWorkspace: UUID
        let activeWorkspace: UUID
        var controllers: [TerminalController] = []
        var windows: [NSWindow] = []
        var group: Tako.CustomTabGroup!

        init(windowCount: Int) {
            hiddenWorkspace = store.createWorkspace(name: "Hidden").id
            activeWorkspace = store.createWorkspace(name: "Active").id
            // Spare unassigned windows participate in the live window model.
            // Construct exactly the windows whose workspaces the case arranges.
            for _ in 0..<windowCount {
                let (controller, window) = TerminalTestSupport.makeController()
                controllers.append(controller)
                windows.append(window)
            }
        }

        func arrange(hidden: [NSWindow], active: [NSWindow], physical: [NSWindow]) {
            for window in hidden { store.assignTab(tabIdentifier: window.stableTabIdentifier, to: hiddenWorkspace) }
            for window in active { store.assignTab(tabIdentifier: window.stableTabIdentifier, to: activeWorkspace) }
            group = Tako.CustomTabGroup.group(for: physical[0])
            for window in physical.dropFirst() { Tako.CustomTabGroup.join(window, to: physical[0], select: false) }
            #expect(store.switchWorkspace(to: activeWorkspace))
            #expect(group.windows == physical)
            #expect(group.visibleWindows == active)
            if let parent = active.first {
                group.select(parent)
                expectSelection(parent)
            }
        }

        func newTab(from parent: NSWindow, select: Bool) throws -> NSWindow {
            let app = controllers[0].tako
            #expect(app.config.windowNewTabPosition != "end")
            let controller = try #require(withInjectedWindowSystem {
                TerminalController.newTab(app, from: parent, select: select)
            })
            // The selection branch runs, but its queued GUI presentation must not.
            controller.cancelPendingInitialPresentation()
            controllers.append(controller)
            let window = try #require(controller.window)
            #expect(!window.isVisible)
            return window
        }

        func expectOrder(active: [NSWindow], hidden: [NSWindow]) {
            #expect(group.visibleWindows == active)
            #expect(store.workspace(for: activeWorkspace)?.tabIdentifiers == active.map(\.stableTabIdentifier))
            #expect(store.workspace(for: hiddenWorkspace)?.tabIdentifiers == hidden.map(\.stableTabIdentifier))
            #expect(group.windows.filter { hidden.contains($0) } == hidden)
            #expect(hidden.allSatisfy { !$0.isVisible })
        }

        func expectSelection(_ window: NSWindow) {
            #expect(group.selectedWindow === window)
            #expect(store.activeWorkspace.activeTabIdentifier == window.stableTabIdentifier)
        }
    }
}
