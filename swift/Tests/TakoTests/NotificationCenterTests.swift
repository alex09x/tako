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

@Suite
@MainActor
struct NotificationCenterTests {
    private func makeTestDefaults() -> UserDefaults {
        let suiteName = "tako.test.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func notificationStoreRecordsAndPersistsAcrossRelaunch() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        let surface1 = UUID()
        let surface2 = UUID()

        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1050)
        let t2 = Date(timeIntervalSince1970: 1100)

        store.addNotification(
            id: "notif-1",
            surfaceId: surface1,
            paneTitle: "Server",
            title: "Started",
            body: "Server listening on 8080",
            urgency: 1,
            unread: true,
            time: t0
        )

        store.addNotification(
            id: "notif-2",
            surfaceId: surface2,
            paneTitle: "Build",
            title: "Build Failed",
            body: "Error on line 42",
            urgency: 2,
            unread: true,
            time: t1
        )

        store.addNotification(
            id: "notif-3",
            surfaceId: surface1,
            paneTitle: "Server",
            title: "Request Log",
            body: "GET /status 200",
            urgency: 0,
            unread: false,
            time: t2
        )

        #expect(store.records.count == 3)
        #expect(store.totalUnreadCount() == 2)
        #expect(store.unreadCount(for: surface1) == 1)
        #expect(store.unreadCount(for: surface2) == 1)

        // Simulate application relaunch with fresh NotificationStore instance on same defaults
        let relaunchedStore = NotificationStore(defaults: defaults)

        #expect(relaunchedStore.records.count == 3)
        #expect(relaunchedStore.totalUnreadCount() == 2)
        #expect(relaunchedStore.unreadCount(for: surface1) == 1)
        #expect(relaunchedStore.unreadCount(for: surface2) == 1)

        // Verify ordering: newest first
        #expect(relaunchedStore.records[0].id == "notif-3")
        #expect(relaunchedStore.records[0].unread == false)
        #expect(relaunchedStore.records[1].id == "notif-2")
        #expect(relaunchedStore.records[1].unread == true)
        #expect(relaunchedStore.records[2].id == "notif-1")
        #expect(relaunchedStore.records[2].unread == true)
    }

    @Test func unreadStatePerPaneAndTabIsolation() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        let paneA = UUID()
        let paneB = UUID()

        store.addNotification(
            id: "a1",
            surfaceId: paneA,
            paneTitle: "Pane A",
            title: "Task Done",
            body: "All tests passed",
            urgency: 1,
            unread: true
        )

        store.addNotification(
            id: "a2",
            surfaceId: paneA,
            paneTitle: "Pane A",
            title: "Deploy Ready",
            body: "Ready for review",
            urgency: 1,
            unread: true
        )

        #expect(store.unreadCount(for: paneA) == 2)
        #expect(store.unreadCount(for: paneB) == 0)
        #expect(store.totalUnreadCount() == 2)

        // Focusing Pane A marks its notifications as read
        store.markRead(surfaceId: paneA)

        #expect(store.unreadCount(for: paneA) == 0)
        #expect(store.unreadCount(for: paneB) == 0)
        #expect(store.totalUnreadCount() == 0)
    }

    @Test func focusingPaneMarksItReadWithoutAffectingOtherPanes() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        let devPane1 = UUID()
        let devPane2 = UUID()
        let devPane3 = UUID()

        store.addNotification(id: "n1", surfaceId: devPane1, paneTitle: "Pane 1", title: "T1", body: "B1", unread: true)
        store.addNotification(id: "n2", surfaceId: devPane2, paneTitle: "Pane 2", title: "T2", body: "B2", unread: true)
        store.addNotification(id: "n3", surfaceId: devPane3, paneTitle: "Pane 3", title: "T3", body: "B3", unread: true)

        #expect(store.totalUnreadCount() == 3)
        #expect(store.unreadCount(for: devPane1) == 1)
        #expect(store.unreadCount(for: devPane2) == 1)
        #expect(store.unreadCount(for: devPane3) == 1)

        // User visits only Pane 2: nothing is marked read that the user did not see
        store.markRead(surfaceId: devPane2)

        #expect(store.unreadCount(for: devPane2) == 0)
        #expect(store.unreadCount(for: devPane1) == 1)
        #expect(store.unreadCount(for: devPane3) == 1)
        #expect(store.totalUnreadCount() == 2)
    }

    @Test func jumpToLatestUnreadNavigation() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        let pane1 = UUID()
        let pane2 = UUID()

        let t1 = Date(timeIntervalSince1970: 100)
        let t2 = Date(timeIntervalSince1970: 200)

        store.addNotification(id: "older", surfaceId: pane1, paneTitle: "P1", title: "Old", body: "Text", unread: true, time: t1)
        store.addNotification(id: "newer", surfaceId: pane2, paneTitle: "P2", title: "New", body: "Text", unread: true, time: t2)

        let latest = store.latestUnread()
        #expect(latest?.id == "newer")
        #expect(latest?.surfaceId == pane2)

        // Once pane 2 is marked read, next latest unread is pane 1
        store.markRead(surfaceId: pane2)
        let nextLatest = store.latestUnread()
        #expect(nextLatest?.id == "older")
        #expect(nextLatest?.surfaceId == pane1)

        store.markRead(surfaceId: pane1)
        #expect(store.latestUnread() == nil)
    }

    @Test func markAllReadClearsAllUnreadAcrossPanes() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        for i in 1...5 {
            store.addNotification(
                id: "notif-\(i)",
                surfaceId: UUID(),
                paneTitle: "Pane \(i)",
                title: "Alert \(i)",
                body: "Body \(i)",
                unread: true
            )
        }

        #expect(store.totalUnreadCount() == 5)
        store.markAllRead()
        #expect(store.totalUnreadCount() == 0)
        #expect(store.latestUnread() == nil)
    }

    @Test func clearRemovesAllRecords() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        store.addNotification(id: "1", surfaceId: UUID(), paneTitle: "P", title: "T", body: "B")
        store.addNotification(id: "2", surfaceId: UUID(), paneTitle: "P", title: "T", body: "B")

        #expect(store.records.count == 2)
        store.clear()
        #expect(store.records.isEmpty)
        #expect(store.totalUnreadCount() == 0)
    }

    @Test func attentionRingRequirementEvaluation() {
        let defaults = makeTestDefaults()
        let store = NotificationStore(defaults: defaults)

        let surfaceId = UUID()

        // No unread notifications -> 0 unread
        #expect(store.unreadCount(for: surfaceId) == 0)

        // Incoming unread notification -> needs attention
        store.addNotification(id: "ring-1", surfaceId: surfaceId, paneTitle: "Pane", title: "Needs Attention", body: "Action required", unread: true)
        #expect(store.unreadCount(for: surfaceId) == 1)

        // User focuses pane -> unread cleared
        store.markRead(surfaceId: surfaceId)
        #expect(store.unreadCount(for: surfaceId) == 0)
    }
}
