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

/// A session row's “New Terminal in Session”, “Mark as Read” and
/// “Reconnect” reach the real session: a split in its tab, the crab's
/// unread mark, a lost session's own retry.
@Suite(.serialized) @MainActor
struct SidebarRowActionsTests {
    private func item(for window: NSWindow, surface: Tako.SurfaceView) -> SessionSidebarItem {
        SessionSidebarItem(id: "row", surfaceId: surface.id, index: 0, isSelected: true, title: "fish", status: .idle,
                           workingDirectory: "/tmp", indentationLevel: 1, workspaceId: WorkspaceStore.shared.activeWorkspaceId,
                           tabId: window.stableTabIdentifier)
    }

    @Test func markReadClearsTheUnreadMarkWithoutFocusing() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        let store = SessionSidebarStore(defaults: UserDefaults(suiteName: "test.rowactions.\(UUID())")!)
        let row = item(for: window, surface: surface)

        surface.crab.unread = true
        #expect(store.rowHasUnread(row, around: window))
        store.markRowRead(row, around: window)
        #expect(!surface.crab.unread)
        #expect(!store.rowHasUnread(row, around: window))
    }

    @Test func reconnectShowsOnlyForALostSessionAndRunsItsRetry() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        let store = SessionSidebarStore(defaults: UserDefaults(suiteName: "test.rowactions.\(UUID())")!)
        let row = item(for: window, surface: surface)

        // A test pane has no session daemon behind it and may already wait to retry.
        surface.sessionRetry = nil
        #expect(!store.rowCanReconnect(row, around: window), "a live session offers to reconnect")
        var retried = 0
        surface.sessionRetry = { retried += 1 }
        #expect(store.rowCanReconnect(row, around: window))
        store.reconnectRow(row, around: window)
        #expect(retried == 1)
    }

    @Test func aNewTerminalInTheSessionIsASplitInItsTab() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        controller.showWindow(nil)
        let store = SessionSidebarStore(defaults: UserDefaults(suiteName: "test.rowactions.\(UUID())")!)
        let before = store.surfaces(in: window).count

        store.newTerminal(inSession: item(for: window, surface: surface), around: window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        #expect(store.surfaces(in: window).count == before + 1,
                "focused \(String(describing: controller.focusedSurface?.id)), tree \(Array(controller.surfaceTree).count)")
        #expect(store.surfaces(in: window).contains { $0 === surface }, "the session's own terminal was replaced")
    }
}
