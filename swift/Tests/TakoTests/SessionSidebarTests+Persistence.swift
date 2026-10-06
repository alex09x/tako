/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import AppKit
import Foundation
@testable import Tako

@MainActor
extension SessionSidebarTests {
    @Test func tabIdentifierAndDescriptionPersistAcrossWindowRestoration() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Restored Tab Surface"
        win.contentView = surf1

        let initialItems = store.items(for: win)
        let tabId = initialItems[0].id
        #expect(tabId == win.stableTabIdentifier)

        // Set description using tabId
        store.setDescription("Critical Dev Server", for: tabId)
        #expect(store.items(for: win)[0].userDescription == "Critical Dev Server")

        // Simulate encode restorable state
        let internalState = TerminalRestorableState.InternalState(
            focusedSurface: surf1.id.uuidString,
            surfaceTree: SplitTree(view: surf1),
            tabIdentifier: win.stableTabIdentifier
        )
        #expect(internalState.tabIdentifier == tabId)

        // Simulate window reconstruction on restore
        let restoredWin = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        restoredWin.contentView = surf1
        if let restoredTabId = internalState.tabIdentifier {
            restoredWin.stableTabIdentifier = restoredTabId
        }

        let restoredItems = store.items(for: restoredWin)
        #expect(restoredItems[0].id == tabId)
        #expect(restoredItems[0].userDescription == "Critical Dev Server")

        // Also verify surfaceIds fallback when window restoration did not have tabIdentifier (legacy migration)
        let legacyDefaults = createTestDefaults()
        let legacySurf = Tako.SurfaceView(frame: .zero)
        legacyDefaults.set([legacySurf.id.uuidString: "Legacy Note"], forKey: SessionSidebarStore.descriptionsKey)
        let legacyStore = SessionSidebarStore(defaults: legacyDefaults)
        let legacyWin = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        legacyWin.contentView = legacySurf
        let legacyItems = legacyStore.items(for: legacyWin)
        #expect(legacyItems[0].userDescription == "Legacy Note")
        // Migrated into stableTabIdentifier
        #expect(legacyStore.description(for: legacyWin.stableTabIdentifier) == "Legacy Note")
        // Removed from surface ID to prevent leakage
        #expect(legacyStore.description(for: legacySurf.id.uuidString) == nil)
    }

    @Test func latestNotificationSelectsRecordWithLatestTimestamp() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let notifDefaults = createTestDefaults()
        let notifStore = NotificationStore(defaults: notifDefaults)

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        win.contentView = surf
        let sid = surf.id

        // Inject first notification at t=1000
        notifStore.addNotification(
            id: "notif-1",
            surfaceId: sid,
            paneTitle: "Pane",
            title: "First Notification",
            body: "Body 1",
            time: Date(timeIntervalSince1970: 1000)
        )
        // Inject second notification at t=2000
        notifStore.addNotification(
            id: "notif-2",
            surfaceId: sid,
            paneTitle: "Pane",
            title: "Second Notification",
            body: "Body 2",
            time: Date(timeIntervalSince1970: 2000)
        )

        // Temporary swap of NotificationStore.shared records for testing
        _ = NotificationStore.shared.records
        defer {
            NotificationStore.shared.loadFromDefaults()
        }
        for rec in notifStore.records {
            NotificationStore.shared.addNotification(
                id: rec.id,
                surfaceId: rec.surfaceId,
                paneTitle: rec.paneTitle,
                title: rec.title,
                body: rec.body,
                time: rec.time
            )
        }

        #expect(store.items(for: win)[0].latestNotification == "Second Notification")

        // Update notif-1 in place with newer timestamp t=3000
        NotificationStore.shared.addNotification(
            id: "notif-1",
            surfaceId: sid,
            paneTitle: "Pane",
            title: "Updated First Notification",
            body: "Body 1 Updated",
            time: Date(timeIntervalSince1970: 3000)
        )

        #expect(store.items(for: win)[0].latestNotification == "Updated First Notification")
    }

    @Test func sidebarFiltersAreScopedPerWindowGroup() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Frontend Window"
        win1.contentView = surf1

        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf2.title = "Backend Window"
        win2.contentView = surf2

        // By default, both show their respective window
        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win2).count == 1)

        // Scope filter to win1
        store.setFilterText("Frontend", for: win1)
        #expect(store.filterText(for: win1) == "Frontend")
        #expect(store.filterText(for: win2).isEmpty)

        #expect(store.items(for: win1).count == 1)
        #expect(store.items(for: win1)[0].title == "Frontend Window")
        #expect(store.items(for: win2).count == 1)
        #expect(store.items(for: win2)[0].title == "Backend Window")

        // Filter win1 to something that doesn't match
        store.setFilterText("Nomatch", for: win1)
        #expect(store.items(for: win1).isEmpty)
        #expect(store.items(for: win2).count == 1)

        // Reset win1
        store.setFilterText("", for: win1)

        // Scope filterNeedsAttention to win1
        let win1B = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1B = Tako.SurfaceView(frame: .zero)
        surf1B.title = "Frontend Background Worker"
        surf1B.crab.setStatus(.error, text: nil)
        win1B.contentView = surf1B
        Tako.CustomTabGroup.join(win1B, to: win1, select: false)
        let group1 = Tako.CustomTabGroup.group(for: win1)
        group1.select(win1)

        store.setFilterNeedsAttention(true, for: win1)
        #expect(store.filterNeedsAttention(for: win1) == true)
        #expect(store.filterNeedsAttention(for: win2) == false)

        // win1's group filtered to items needing attention shows only win1B (error)
        let win1Filtered = store.items(for: win1)
        #expect(win1Filtered.count == 1)
        #expect(win1Filtered[0].title == "Frontend Background Worker")

        // win2 is unfiltered and still shows its 1 normal tab
        #expect(store.items(for: win2).count == 1)
        #expect(store.items(for: win2)[0].title == "Backend Window")
    }

    @Test func sidebarFiltersPersistWhenSwitchingTabsInSameGroup() {
        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)

        let win1 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let win2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf1 = Tako.SurfaceView(frame: .zero)
        let surf2 = Tako.SurfaceView(frame: .zero)
        surf1.title = "Frontend Client"
        surf2.title = "Frontend Tests"
        win1.contentView = surf1
        win2.contentView = surf2

        Tako.CustomTabGroup.join(win2, to: win1, select: false)
        let group = Tako.CustomTabGroup.group(for: win1)
        group.select(win1)

        // Set filter on win1
        store.setFilterText("Tests", for: win1)
        store.setFilterNeedsAttention(true, for: win1)

        // Switching to win2 in the same tab group preserves the filter
        #expect(store.filterText(for: win2) == "Tests")
        #expect(store.filterNeedsAttention(for: win2) == true)

        let itemsFromWin2 = store.items(for: win2)
        // With "Tests" and needsAttention (neither has attention), filtered list is empty
        #expect(itemsFromWin2.isEmpty)

        // Clear needsAttention for group
        store.setFilterNeedsAttention(false, for: win2)
        #expect(store.filterNeedsAttention(for: win1) == false)
        let itemsWithTextOnly = store.items(for: win2)
        #expect(itemsWithTextOnly.count == 1)
        #expect(itemsWithTextOnly[0].title == "Frontend Tests")
    }

    @Test func commandProgressingThroughAttentionStatusInvalidatesInspectionsOnTerminalStatus() async throws {
        let repoURL = try createTestGitRepository(branch: "branch-start")
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let defaults = createTestDefaults()
        let store = SessionSidebarStore(defaults: defaults)
        store.optInGit = true

        let win = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let surf = Tako.SurfaceView(frame: .zero)
        surf.pty?.terminate()
        surf.pwd = repoURL.path
        win.contentView = surf

        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)
        #expect(store.items(for: win)[0].gitBranch == "branch-start")

        // Switch branch on disk
        let headFile = repoURL.appendingPathComponent(".git/HEAD")
        try "ref: refs/heads/branch-interactive\n".write(to: headFile, atomically: true, encoding: .utf8)

        // Command starts running
        surf.crab.setStatus(.running, text: nil)

        // Command enters attention state (.waitingForInput) - intermediate state, must NOT invalidate
        surf.crab.setStatus(.waitingForInput, text: nil)
        #expect(store.items(for: win)[0].gitBranch == "branch-start")

        // Command completes (.done) - terminal state from attention state, MUST invalidate
        surf.crab.setStatus(.done, text: nil)

        _ = store.items(for: win)
        try await waitForGitInspection(store: store, directory: repoURL.path)
        #expect(store.items(for: win)[0].gitBranch == "branch-interactive")
    }


}
