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

@Suite(.serialized)
@MainActor
struct AttentionNavigationTests {

    private func makeSurface(
        title: String = "Test Pane",
        pwd: String = "/Users/alex/tako",
        status: Tako.PaneStatus = .idle
    ) -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.title = title
        view.pwd = pwd
        view.crab.setStatus(status, text: nil)
        return view
    }

    private func makeController(surfaces: [Tako.SurfaceView]) -> BaseTerminalController {
        guard let first = surfaces.first else {
            fatalError("Must provide at least one surface")
        }
        var tree = SplitTree<Tako.SurfaceView>(view: first)
        var prev = first
        for s in surfaces.dropFirst() {
            tree = (try? tree.inserting(view: s, at: prev, direction: .right)) ?? tree
            prev = s
        }
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        return controller
    }

    // MARK: - Per-Pane Mute Tests (B7)

    @Test func mutePreventsRaisingAttentionWithoutLosingStatus() {
        let manager = AttentionManager.shared
        manager.reset()

        let surface = makeSurface(title: "Noisy Worker", status: .error)
        NotificationStore.shared.clear()
        NotificationStore.shared.addNotification(
            id: "notif-1",
            surfaceId: surface.id,
            paneTitle: "Noisy Worker",
            title: "Build Failed",
            body: "Exit code 1",
            unread: true
        )

        // Without mute, the pane requires attention
        #expect(manager.hasUnseenAttention(surface: surface))
        #expect(surface.crab.paneStatus == .error)
        #expect(NotificationStore.shared.unreadCount(for: surface.id) == 1)

        // Mute the pane
        surface.isAttentionMuted = true
        #expect(surface.isAttentionMuted)
        #expect(manager.isMuted(surfaceId: surface.id))

        // When muted: stops raising attention without losing status or notifications
        #expect(!manager.hasUnseenAttention(surface: surface))
        #expect(surface.crab.paneStatus == .error)
        #expect(NotificationStore.shared.unreadCount(for: surface.id) == 1)

        // Unmute the pane: attention is restored
        surface.toggleAttentionMute()
        #expect(!surface.isAttentionMuted)
        #expect(!manager.isMuted(surfaceId: surface.id))
        #expect(manager.hasUnseenAttention(surface: surface))
    }

    // MARK: - Navigation Across Windows (B7)

    @Test func attentionNavigationDiscoversNextAndPreviousPanesAcrossWindows() {
        let manager = AttentionManager.shared
        manager.reset()
        NotificationStore.shared.clear()

        let s1 = makeSurface(title: "Idle 1", status: .idle)
        let s2 = makeSurface(title: "Error 2", status: .error)
        let s3 = makeSurface(title: "Approval 3", status: .needsApproval)
        let s4 = makeSurface(title: "Idle 4", status: .idle)

        let controller1 = makeController(surfaces: [s1, s2])
        let controller2 = makeController(surfaces: [s3, s4])
        let controllers = [controller1, controller2]

        // Register attention events
        manager.recordAttentionEvent(for: s2.id)
        manager.recordAttentionEvent(for: s3.id)

        let attentionPanes = manager.attentionSurfaces(fromControllers: controllers)
        #expect(attentionPanes.count == 2)
        #expect(attentionPanes.contains { $0.id == s2.id })
        #expect(attentionPanes.contains { $0.id == s3.id })

        // Next navigation from s1 lands on s2
        let next1 = manager.nextAttentionSurface(from: s1, inControllers: controllers)
        #expect(next1?.id == s2.id)

        // Next navigation from s2 lands on s3
        let next2 = manager.nextAttentionSurface(from: s2, inControllers: controllers)
        #expect(next2?.id == s3.id)

        // Next navigation wraps circularly from s3 back to s2
        let next3 = manager.nextAttentionSurface(from: s3, inControllers: controllers)
        #expect(next3?.id == s2.id)

        // Previous navigation backwards
        let prev1 = manager.previousAttentionSurface(from: s1, inControllers: controllers)
        #expect(prev1?.id == s3.id)

        let prev2 = manager.previousAttentionSurface(from: s3, inControllers: controllers)
        #expect(prev2?.id == s2.id)
    }

    // MARK: - Already-Seen Pane Tracking (B7)

    @Test func attentionNavigationNeverLandsOnAlreadySeenPane() {
        let manager = AttentionManager.shared
        manager.reset()
        NotificationStore.shared.clear()

        let s1 = makeSurface(title: "Main", status: .idle)
        let s2 = makeSurface(title: "Task A", status: .error)
        let s3 = makeSurface(title: "Task B", status: .waitingForInput)

        let controller = makeController(surfaces: [s1, s2, s3])
        let controllers = [controller]

        manager.recordAttentionEvent(for: s2.id)
        manager.recordAttentionEvent(for: s3.id)

        #expect(manager.hasUnseenAttention(surface: s2))
        #expect(manager.hasUnseenAttention(surface: s3))

        // User views/focuses s2 -> marked as seen
        manager.markSeen(surface: s2)
        #expect(manager.isAlreadySeen(surfaceId: s2.id))
        #expect(!manager.hasUnseenAttention(surface: s2))

        // Attention navigation now completely skips s2 and lands only on s3
        let target = manager.nextAttentionSurface(from: s1, inControllers: controllers)
        #expect(target?.id == s3.id)

        // If s3 is also seen:
        manager.markSeen(surface: s3)
        #expect(!manager.hasAnyUnseenAttention(fromControllers: controllers))
        #expect(manager.nextAttentionSurface(from: s1, inControllers: controllers) == nil)

        // When a NEW event occurs on s2, it becomes unseen again
        manager.recordAttentionEvent(for: s2.id)
        #expect(!manager.isAlreadySeen(surfaceId: s2.id))
        #expect(manager.hasUnseenAttention(surface: s2))
        #expect(manager.nextAttentionSurface(from: s1, inControllers: controllers)?.id == s2.id)
    }

    // MARK: - Muted Panes are Skipped (B7)

    @Test func attentionNavigationNeverLandsOnMutedPane() {
        let manager = AttentionManager.shared
        manager.reset()
        NotificationStore.shared.clear()

        let s1 = makeSurface(title: "Prompt", status: .idle)
        let s2 = makeSurface(title: "Noisy Service", status: .error)
        let s3 = makeSurface(title: "Important Build", status: .needsApproval)

        let controller = makeController(surfaces: [s1, s2, s3])
        let controllers = [controller]

        manager.recordAttentionEvent(for: s2.id)
        manager.recordAttentionEvent(for: s3.id)

        // Mute s2
        s2.isAttentionMuted = true

        let candidates = manager.attentionSurfaces(fromControllers: controllers)
        #expect(candidates.count == 1)
        #expect(candidates[0].id == s3.id)

        // Next lands directly on s3, skipping s2
        let target = manager.nextAttentionSurface(from: s1, inControllers: controllers)
        #expect(target?.id == s3.id)
    }

    // MARK: - Go Back History Tests (B7)

    @Test func goBackAlwaysReturnsToThePreviousPane() {
        let manager = AttentionManager.shared
        manager.reset()

        let s1 = makeSurface(title: "Origin Pane")
        let s2 = makeSurface(title: "Attention Target", status: .error)

        let controller = makeController(surfaces: [s1, s2])
        let controllers = [controller]

        #expect(!manager.canGoBack)

        // User is at s1, jumps to s2
        manager.recordJump(from: s1.id)
        #expect(manager.canGoBack)

        // "Go back" returns to s1
        let back1 = manager.resolveGoBackTarget(currentSurfaceId: s2.id, inControllers: controllers)
        #expect(back1?.id == s1.id)

        // Invoking "Go back" again from s1 toggles back to s2
        let back2 = manager.resolveGoBackTarget(currentSurfaceId: s1.id, inControllers: controllers)
        #expect(back2?.id == s2.id)
    }

    @Test func multiStepJumpHistoryUnwindsCleanly() {
        let manager = AttentionManager.shared
        manager.reset()

        let s1 = makeSurface(title: "Pane 1")
        let s2 = makeSurface(title: "Pane 2")
        let s3 = makeSurface(title: "Pane 3")

        let controller = makeController(surfaces: [s1, s2, s3])
        let controllers = [controller]

        // User jumps: s1 -> s2 -> s3
        manager.recordJump(from: s1.id)
        manager.recordJump(from: s2.id)

        // From s3, go back returns s2
        let step1 = manager.resolveGoBackTarget(currentSurfaceId: s3.id, inControllers: controllers)
        #expect(step1?.id == s2.id)

        // From s2, go back returns s1
        let step2 = manager.resolveGoBackTarget(currentSurfaceId: s2.id, inControllers: controllers)
        #expect(step2?.id == s1.id)
    }

    // MARK: - Controller Integration Tests

    @Test func controllerMenuValidationReflectsAttentionAndHistory() {
        let manager = AttentionManager.shared
        manager.reset()

        let s1 = makeSurface(title: "Pane 1")
        let controller = makeController(surfaces: [s1])
        controller.focusedSurface = s1

        // Initially no attention panes, no history
        #expect(!manager.hasAnyUnseenAttention(fromControllers: [controller]))
        #expect(!manager.canGoBack)

        let jumpItem = NSMenuItem(title: "Next Attention", action: #selector(BaseTerminalController.jumpToNextAttention(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(jumpItem))

        let backItem = NSMenuItem(title: "Go Back", action: #selector(BaseTerminalController.goBackToPreviousPane(_:)), keyEquivalent: "")
        #expect(!controller.validateMenuItem(backItem))

        let muteItem = NSMenuItem(title: "Mute Attention", action: #selector(BaseTerminalController.toggleAttentionMute(_:)), keyEquivalent: "")
        #expect(controller.validateMenuItem(muteItem))
        #expect(muteItem.title == "Mute Attention")

        // Mute pane
        controller.toggleAttentionMute(nil)
        #expect(s1.isAttentionMuted)
        #expect(controller.validateMenuItem(muteItem))
        #expect(muteItem.title == "Unmute Attention")
    }

    // MARK: - Startup / Restoration Tests (B7 Finding Fix)

    @Test func testRestoredUnreadNotificationSeedsAttentionAndNavigatesUntilSeen() throws {
        let manager = AttentionManager.shared
        manager.reset()

        let s1 = makeSurface(title: "Restored Surface", status: .idle)
        let controller = makeController(surfaces: [s1])

        let unreadRecord = NotificationRecord(
            id: "restored-notif-1",
            surfaceId: s1.id,
            paneTitle: "Restored Surface",
            title: "Background Job Complete",
            body: "Output available",
            unread: true
        )
        let encoded = try JSONEncoder().encode([unreadRecord])

        let suiteName = "test.attention.restored.\(UUID().uuidString)"
        let mockDefaults = UserDefaults(suiteName: suiteName)!
        mockDefaults.set(encoded, forKey: NotificationStore.userDefaultsKey)

        // Instantiate store from defaults (simulating app relaunch)
        let store = NotificationStore(defaults: mockDefaults)
        #expect(store.unreadCount(for: s1.id) == 1)

        // AttentionManager must recognize the restored unread notification as unseen
        #expect(!manager.isAlreadySeen(surfaceId: s1.id))
        #expect(manager.hasUnseenAttention(surface: s1, notificationStore: store))
        #expect(manager.nextAttentionSurface(from: nil, inControllers: [controller], notificationStore: store)?.id == s1.id)

        // Once the user visits/sees the surface, it is marked seen and no longer targeted
        manager.markSeen(surface: s1)
        #expect(manager.isAlreadySeen(surfaceId: s1.id))
        #expect(!manager.hasUnseenAttention(surface: s1, notificationStore: store))
        #expect(manager.nextAttentionSurface(from: nil, inControllers: [controller], notificationStore: store) == nil)

        mockDefaults.removePersistentDomain(forName: suiteName)
    }
}

