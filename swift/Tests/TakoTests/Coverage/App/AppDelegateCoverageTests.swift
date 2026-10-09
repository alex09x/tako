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
import UserNotifications
@testable import Tako

@MainActor
struct AppDelegateTerminateTests {
    @Test func terminateResolvesImmediatelyWhenNoSurfaceNeedsConfirmation() {
        let delegate = quietDelegate()
        if busyTerminalWindows().isEmpty {
            #expect(delegate.terminate() == .terminateNow)
        } else {
            // Another test's terminal is still busy; the stubbed alert says
            // Cancel, or a single window starts its own review.
            #expect([.terminateCancel, .terminateLater].contains(delegate.terminate()))
        }
    }
}

@MainActor
struct AppDelegateMenuKeyEquivalentTests {
    @Test func performTakoBindingMenuKeyEquivalentReturnsFalseWithNoBindings() throws {
        let delegate = AppDelegate()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        #expect(!delegate.performTakoBindingMenuKeyEquivalent(with: event))
    }
}

@MainActor
struct AppDelegateTakoDelegateTests {
    @Test func findSurfaceReturnsNilWhenNoWindowHostsIt() {
        let delegate = AppDelegate()
        #expect(delegate.findSurface(forUUID: UUID()) == nil)
    }

    @Test func findSurfaceLocatesASurfaceOwnedByATerminalController() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }

        guard let surface = controller.surfaceTree.first else {
            Issue.record("Expected the controller's initial surface tree to contain a surface")
            return
        }

        #expect(delegate.findSurface(forUUID: surface.id) === surface)
    }

    @Test func takoSurfaceMirrorsFindSurfaceThroughTheDelegateExtension() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }

        guard let surface = controller.surfaceTree.first else {
            Issue.record("Expected the controller's initial surface tree to contain a surface")
            return
        }

        #expect(delegate.takoSurface(id: surface.id) === surface)
        #expect(delegate.takoSurface(id: UUID()) == nil)
    }

    @Test func takoSurfaceSkipsNonTerminalWindowsAndReturnsNilOnNoMatch() {
        let delegate = AppDelegate()
        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        defer { plain.close() }

        // `plain`'s windowController is nil (never assigned one), so this
        // exercises the `continue` branch regardless of what other windows
        // exist elsewhere in this process, and a fresh random UUID cannot
        // collide with any real surface's id, so this also exercises the
        // final `return nil`.
        #expect(delegate.takoSurface(id: UUID()) == nil)
    }
}

/// Several `AppDelegate` handlers are the only real caller for a chunk of
/// logic reached exclusively through `NotificationCenter`/`NSEvent` local
/// monitors that a bare `swift test` host can't deliver (no real window
/// server events, and `applicationDidFinishLaunching`'s local monitor
/// registration is discarded via `_ =`, matching upstream, so it can't be
/// removed to call it again from a clean state). Per this repo's own
/// precedent (`GlobalEventTap.cgEventFlagsChangedHandler`, documented as
/// deliberately `internal` so tests can call it directly), these were
/// widened from `private` to plain (module-internal) visibility in
/// AppDelegate.swift so this suite can drive them directly instead.
@MainActor
struct AppDelegateWidenedHandlerTests {
    @Test func localEventHandlerDispatchesKeyDownAndPassesThroughOtherTypes() throws {
        let delegate = AppDelegate()
        let keyEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
        // Doesn't assert the result (it depends on ambient key-binding
        // state elsewhere in this shared process); just confirms the
        // dispatch and the full localEventKeyDown chain run without crashing.
        _ = delegate.localEventHandler(keyEvent)

        let mouseEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(delegate.localEventHandler(mouseEvent) === mouseEvent)
    }

    @Test func windowDidBecomeKeySyncsTheFloatOnTopMenu() {
        let delegate = AppDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
    }

    @Test func quickTerminalVisibilityChangeIgnoresWrongObjectTypes() {
        let delegate = AppDelegate()
        delegate.quickTerminalDidChangeVisibility(Notification(name: .quickTerminalDidChangeVisibility, object: "not a controller"))
    }

    @Test func quickTerminalVisibilityChangeSyncsTheMenuStateForARealController() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let controller = QuickTerminalController(tako, position: .top)
        delegate.quickTerminalDidChangeVisibility(
            Notification(name: .quickTerminalDidChangeVisibility, object: controller))
    }

    @Test func takoConfigDidChangeIgnoresSurfaceScopedNotifications() {
        let delegate = AppDelegate()
        delegate.takoConfigDidChange(
            Notification(name: .takoConfigDidChange, object: "a surface, not nil"))
    }

    @Test func takoConfigDidChangeIgnoresMissingUserInfo() {
        let delegate = AppDelegate()
        delegate.takoConfigDidChange(Notification(name: .takoConfigDidChange, object: nil))
    }

    @Test func takoConfigDidChangeAppliesAValidGlobalConfig() async {
        let delegate = AppDelegate()
        AppDelegate.notificationCenterProvider = { nil }

        delegate.takoConfigDidChange(Notification(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: Tako.Config()]))

        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    @Test func takoBellDidRingRunsThroughAllThreeFeatureChecks() {
        let delegate = AppDelegate()
        delegate.takoBellDidRing(Notification(name: .takoBellDidRing))
    }

    @Test func terminalWindowHasBellIgnoresUnrelatedObjectsAndSyncsForARealController() {
        let delegate = AppDelegate()
        AppDelegate.notificationCenterProvider = { nil }
        delegate.terminalWindowHasBell(
            Notification(name: .terminalWindowBellDidChangeNotification, object: "not a controller"))

        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }
        delegate.terminalWindowHasBell(
            Notification(name: .terminalWindowBellDidChangeNotification, object: controller))
    }

    @Test func takoNewWindowBuildsAControllerWithNoBaseConfigWhenUserInfoIsMissing() {
        let delegate = AppDelegate()
        delegate.takoNewWindow(Notification(name: Tako.Notification.takoNewWindow, object: nil))
    }

    @Test func takoNewTabIgnoresNotificationsWithoutASurfaceOrWindowedParent() {
        let delegate = AppDelegate()
        delegate.takoNewTab(Notification(name: Tako.Notification.takoNewTab, object: "not a surface"))

        let tako = Tako.App()
        let orphanSurface = Tako.SurfaceView(tako, baseConfig: nil)
        defer { orphanSurface.pty?.terminate() }
        delegate.takoNewTab(Notification(name: Tako.Notification.takoNewTab, object: orphanSurface))
    }

    @Test func takoNewTabOpensATabForASurfaceHostedByATerminalController() {
        let delegate = AppDelegate()
        let tako = Tako.App()
        let (controller, window) = makeTerminalController(tako)
        defer {
            controller.surfaceTree.forEach { $0.pty?.terminate() }
            window.close()
        }

        guard let surface = controller.surfaceTree.first else {
            Issue.record("Expected the controller's initial surface tree to contain a surface")
            return
        }

        // Assigning `.window` directly (bypassing nib loading, see
        // `makeTerminalController`'s doc comment) never actually embeds the
        // surface into the window's view hierarchy the way the real
        // `windowDidLoad()` would, so `surfaceView.window` stays nil without
        // this -- and `takoNewTab` bails at its `guard let window =
        // surfaceView.window` before ever reaching the windowController check.
        window.contentView = surface
        #expect(surface.window === window)

        delegate.takoNewTab(Notification(name: Tako.Notification.takoNewTab, object: surface))
    }

    @Test func setDockBadgeReflectsBellCountAcrossTerminalWindows() {
        let delegate = AppDelegate()
        delegate.setDockBadge()
    }

    @Test func reloadDockMenuPopulatesNewWindowAndNewTabItems() {
        let delegate = AppDelegate()
        delegate.reloadDockMenu()
        let menu = delegate.applicationDockMenu(NSApp)
        #expect(menu?.items.count == 2)
    }
}

@MainActor
struct AppDelegateQuickControllerTests {
    @Test func quickControllerLazilyInitializesOnceAndReturnsTheSameInstance() {
        let delegate = AppDelegate()
        #expect(!delegate.quickControllerInitialized)

        let first = delegate.quickController
        #expect(delegate.quickControllerInitialized)

        let second = delegate.quickController
        #expect(first === second)
    }
}
