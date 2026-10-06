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
@testable import Tako

@MainActor
struct QuickTerminalControllerInitTests {
    @Test func defaultsToRestorableWhenNoCommandIsConfigured() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        #expect(controller.restorable)
        #expect(!controller.visible)
    }

    @Test func isNotRestorableWhenABaseCommandIsConfigured() {
        let app = Tako.App()
        var config = Tako.SurfaceConfiguration()
        config.command = "top"
        let controller = QuickTerminalController(app, baseConfig: config)
        #expect(!controller.restorable)
    }

    @Test func positionIsHonored() {
        let (controller, window) = QTTestSupport.makeController(position: .left)
        defer { QTTestSupport.tearDown(controller, window) }
        if case .left = controller.position {
            // expected
        } else {
            Issue.record("expected .left position")
        }
    }
}

@MainActor
struct QuickTerminalControllerLifecycleTests {
    @Test func windowDidLoadConfiguresDelegateAndDisablesRestorable() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }

        #expect(window.delegate === controller)
        #expect(!window.isRestorable)
        #expect(controller.visible)
        #expect(window.isVisible)
        #expect(!controller.surfaceTree.isEmpty)
        #expect(controller.focusedSurface != nil)
    }

    @Test func toggleAnimatesOutWhenVisibleThenBackInWhenHidden() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        #expect(controller.visible)

        controller.toggle()
        QTTestSupport.simulateDeferredAnimateOutCompletion(controller: controller, window: window)
        #expect(!controller.visible)
        #expect(!window.isVisible)

        controller.toggle()
        QTTestSupport.waitUntil { controller.visible }
        QTTestSupport.simulateDeferredAnimateInCompletion(controller: controller, window: window)
        #expect(controller.visible)
        #expect(window.isVisible)
    }

    @Test func animateInIsANoOpWhenAlreadyVisible() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let frameBefore = window.frame
        controller.animateIn()
        #expect(controller.visible)
        #expect(window.frame == frameBefore)
    }

    @Test func animateOutIsANoOpWhenNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        #expect(!controller.visible)
        controller.animateOut()
        #expect(!controller.visible)
        #expect(!window.isVisible)
    }

    @Test func animateInAndOutWithoutAWindowIsANoOp() {
        let app = Tako.App()
        let controller = QuickTerminalController(app, position: .center)
        // `.window` is nil (never assigned, so it's never lazily loaded either
        // -- see QTTestSupport.makeController's doc comment). Both guards
        // must bail before touching `visible`.
        controller.animateIn()
        #expect(!controller.visible)
        controller.animateOut()
        #expect(!controller.visible)
    }

    @Test func saveScreenStateStoresTheCurrentFrameInTheScreenCache() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let screen = try #require(window.screen ?? NSScreen.main)

        controller.saveScreenState(exitFullscreen: true)

        guard screen.displayUUID != nil else { return }
        #expect(controller.screenStateCache.frame(for: screen) == window.frame)
    }

    @Test func saveScreenStateIgnoresAZeroSizedFrame() throws {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        window.setFrame(NSRect(x: 0, y: 0, width: 0, height: 0), display: false)
        let screen = try #require(window.screen ?? NSScreen.main)

        controller.saveScreenState(exitFullscreen: false)

        #expect(controller.screenStateCache.frame(for: screen) == nil)
    }

    @Test func syncAppearanceIsANoOpWhileTheWindowIsNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        let collectionBefore = window.collectionBehavior
        controller.syncAppearance()
        // The early `guard window.isVisible` returns before touching opacity,
        // but collectionBehavior is set unconditionally above that guard.
        #expect(window.collectionBehavior == QuickTerminalSpaceBehavior.move.collectionBehavior)
        _ = collectionBefore
    }

    @Test func syncAppearanceMakesTheWindowOpaqueByDefault() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        // Production only re-syncs appearance once truly visible from inside
        // the (in this test host, dead -- see loadAndAnimateIn's doc comment)
        // animation completion handler, or from `takoConfigDidChange`. Call
        // it directly now that the window is actually visible.
        controller.syncAppearance()
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .windowBackgroundColor)
    }

    @Test func windowDidResizeRecentersForTopPositionKeepingY() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn(position: .top)
        defer { QTTestSupport.tearDown(controller, window) }
        let originalY = window.frame.origin.y
        window.setFrame(NSRect(x: 999, y: originalY, width: window.frame.width - 10, height: window.frame.height), display: false)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        #expect(window.frame.origin.x != 999)
        #expect(window.frame.origin.y == originalY)
    }

    @Test func windowDidResizeRecentersForLeftPositionKeepingX() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn(position: .left)
        defer { QTTestSupport.tearDown(controller, window) }
        let originalX = window.frame.origin.x
        window.setFrame(NSRect(x: originalX, y: -12345, width: window.frame.width, height: window.frame.height - 10), display: false)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        #expect(window.frame.origin.x == originalX)
        #expect(window.frame.origin.y != -12345)
    }

    @Test func windowDidResizeIgnoresNotificationsForAnotherWindow() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        let frameBefore = window.frame

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: other))

        #expect(window.frame == frameBefore)
    }

    @Test func windowDidResizeIgnoresNotificationsWhileNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        let frameBefore = window.frame

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        #expect(window.frame == frameBefore)
    }
}

@MainActor
struct QuickTerminalControllerKeyStateTests {
    @Test func windowDidBecomeKeyIsANoOpWhileNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        // Must not crash without a hidden dock or terminal view container set up.
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(!controller.visible)
    }

    @Test func windowDidResignKeyRestoresPreviousAppOnlyWhenAppIsInactive() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        QTTestSupport.waitUntil(timeout: 1) { NSApplication.shared.isActive }

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))

        // The quick terminal auto-hides on resign key (default config), and since
        // we haven't switched spaces, `.move`'s "haven't moved" branch fires and
        // animates the window back out.
        QTTestSupport.waitUntil(timeout: 2) { !controller.visible }
        #expect(!controller.visible)
    }

    @Test func windowDidResignKeyIsANoOpWhileNotVisible() {
        let (controller, window) = QTTestSupport.makeController()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        #expect(!controller.visible)
    }

    @Test func windowDidResignKeyDoesNotAnimateOutWhileASheetIsAttached() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            QTTestSupport.tearDown(controller, window)
        }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        QTTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        try #require(window.attachedSheet != nil)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))

        #expect(controller.visible)
    }

    @Test func windowDidBecomeKeyRunsTheVisibleSyncPathWithoutCrashing() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        #expect(controller.visible)
        #expect(controller.terminalViewContainer != nil)
    }
}

@MainActor
