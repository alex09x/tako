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
struct QuickTerminalControllerNotificationTests {
    @Test func applicationWillTerminateClearsHiddenDockStateWithoutCrashing() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(controller.visible)
    }

    @Test func onToggleFullscreenIgnoresNonSurfaceObjects() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        // `windowDidLoad()` (in `BaseTerminalController`) always eagerly
        // creates a `NativeFullscreen` style to set up its observers, so
        // `fullscreenStyle` itself is never nil past that point -- the
        // observable "did this notification do anything" signal is whether
        // it actually *entered* fullscreen.
        #expect(controller.fullscreenStyle?.isFullscreen == false)
        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: NSObject())
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }

    @Test func onToggleFullscreenIgnoresSurfacesThatArentFocused() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let other = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        defer { other.close() }
        #expect(controller.fullscreenStyle?.isFullscreen == false)
        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: other)
        #expect(controller.fullscreenStyle?.isFullscreen == false)
    }

    @Test func onToggleFullscreenEntersAndExitsForTheFocusedSurface() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        // `QTTestSupport.makeController` builds the window with
        // `[.borderless, .resizable]` (no `.titled` bit ever set), so
        // `.resizable` -- not `.titled` -- is the bit `enter()`/`exit()`
        // actually flips here.
        #expect(window.styleMask.contains(.resizable))

        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: surface)
        QTTestSupport.waitUntil(timeout: 2) { controller.fullscreenStyle?.isFullscreen == true }
        #expect(controller.fullscreenStyle?.isFullscreen == true)
        // `NonNativeFullscreen.enter()` strips `.titled`/`.resizable`
        // synchronously; only the actual screen-sized `setFrame` call is
        // deferred behind the dead `DispatchQueue.main.async` hop this
        // harness never drains (see `QTTestSupport.loadAndAnimateIn`'s doc
        // comment), so the style mask -- not the frame -- is what's
        // observable here.
        #expect(!window.styleMask.contains(.resizable))

        NotificationCenter.default.post(name: Tako.Notification.takoToggleFullscreen, object: surface)
        QTTestSupport.waitUntil(timeout: 2) { controller.fullscreenStyle?.isFullscreen == false }
        #expect(controller.fullscreenStyle?.isFullscreen == false)
        // `exit()` restores the saved style mask synchronously (unlike
        // `enter()`, it has no deferred `setFrame` hop at all).
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func takoConfigDidChangeIgnoresNotificationsScopedToASurface() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let before = window.isOpaque
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: NSObject(),
            userInfo: [Notification.Name.TakoConfigChangeKey: controller.tako.config])
        #expect(window.isOpaque == before)
    }

    @Test func takoConfigDidChangeIgnoresAMissingConfigPayload() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let before = window.isOpaque
        NotificationCenter.default.post(name: .takoConfigDidChange, object: nil, userInfo: nil)
        #expect(window.isOpaque == before)
    }

    @Test func takoConfigDidChangeAppliesANewGlobalConfigsTransparency() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        try #require(window.isOpaque)

        let translucent = try TemporaryConfig("background-opacity = 0.4\n")
        NotificationCenter.default.post(
            name: .takoConfigDidChange,
            object: nil,
            userInfo: [Notification.Name.TakoConfigChangeKey: translucent])

        #expect(!window.isOpaque)
    }

    @Test func onNewTabIgnoresNonSurfaceObjects() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: NSObject())
        #expect(window.attachedSheet == nil)
    }

    @Test func onNewTabShowsAlertForASurfaceOwnedByThisQuickTerminal() throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            QTTestSupport.tearDown(controller, window)
        }
        let surface = try #require(controller.focusedSurface)
        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: surface)
        QTTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
    }

    @Test func onNewTabIgnoresSurfacesNotHostedInAQuickTerminalWindow() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let foreignSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        foreignWindow.contentView = foreignSurface
        defer { foreignSurface.close(); foreignWindow.close() }

        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: foreignSurface)

        #expect(window.attachedSheet == nil)
    }

    @Test func closeWindowAnimatesOutInsteadOfActuallyClosing() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.closeWindow(controller)
        QTTestSupport.waitUntil { !controller.visible }
        #expect(!controller.visible)
        #expect(controller.window === window)
    }

    @Test func newTabActionShowsTheUnsupportedAlertInsteadOfCreatingATab() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            QTTestSupport.tearDown(controller, window)
        }
        controller.newTab(nil)
        QTTestSupport.waitUntil(timeout: 1) { window.attachedSheet != nil }
        #expect(window.attachedSheet != nil)
    }

    /// `Tako.SurfaceView.surface` is hardcoded to `nil` in this Zig-less shim
    /// (see `Tako+App.swift`), so the guard in `toggleTakoFullScreen` /
    /// `toggleTerminalInspector` that reads it can never see a non-nil value
    /// here; the call these guards protect is unreachable without a real
    /// Zig core behind the surface. Documented gap, not a test workaround.
    @Test func toggleTakoFullScreenAndInspectorActionsAreNoOpsInThisShim() {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        controller.toggleTakoFullScreen(controller)
        controller.toggleTerminalInspector(nil)
        #expect(controller.visible)
    }
}
