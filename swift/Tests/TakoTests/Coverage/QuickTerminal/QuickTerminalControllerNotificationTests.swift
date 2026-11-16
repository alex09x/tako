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

    /// The Quick Terminal refuses a tab with an in-window dialog card
    /// (`TerminalDialogView.alert`), not a sheet: its title, or nil.
    private func noNewTabAlert(in window: NSWindow) -> String? {
        TerminalDialogView.pending(in: window).map(\.title)
    }

    /// The card is presented from a main-actor task, which runs only once the
    /// test yields; spinning the run loop inside the test never lets it run.
    /// The negative cases yield the same way before checking nothing came.
    private func settleAlert(in window: NSWindow) async {
        for _ in 0..<1000 where noNewTabAlert(in: window) == nil { await Task.yield() }
    }

    /// Answers the card if one is up, so the next test starts without it.
    private func dismissAlert(in window: NSWindow) {
        _ = TerminalDialogView.pending(in: window)?.press("OK")
    }

    @Test func onNewTabIgnoresNonSurfaceObjects() async {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { dismissAlert(in: window); QTTestSupport.tearDown(controller, window) }
        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: NSObject())
        await settleAlert(in: window)
        #expect(noNewTabAlert(in: window) == nil)
        #expect(window.attachedSheet == nil)
    }

    @Test func onNewTabShowsAlertForASurfaceOwnedByThisQuickTerminal() async throws {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { dismissAlert(in: window); QTTestSupport.tearDown(controller, window) }
        let surface = try #require(controller.focusedSurface)
        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: surface)
        await settleAlert(in: window)
        #expect(noNewTabAlert(in: window) == "Cannot Create New Tab")
    }

    @Test func onNewTabIgnoresSurfacesNotHostedInAQuickTerminalWindow() async {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { QTTestSupport.tearDown(controller, window) }
        let foreignWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        let foreignSurface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        foreignWindow.contentView = foreignSurface
        defer { foreignSurface.close(); foreignWindow.close() }

        NotificationCenter.default.post(name: Tako.Notification.takoNewTab, object: foreignSurface)

        await settleAlert(in: window)
        #expect(noNewTabAlert(in: window) == nil)
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

    @Test func newTabActionShowsTheUnsupportedAlertInsteadOfCreatingATab() async {
        let (controller, window) = QTTestSupport.loadAndAnimateIn()
        defer { dismissAlert(in: window); QTTestSupport.tearDown(controller, window) }
        let surfacesBefore = Array(controller.surfaceTree).count
        controller.newTab(nil)
        await settleAlert(in: window)
        #expect(noNewTabAlert(in: window) == "Cannot Create New Tab")
        #expect(Array(controller.surfaceTree).count == surfacesBefore, "no tab or terminal was created")
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
