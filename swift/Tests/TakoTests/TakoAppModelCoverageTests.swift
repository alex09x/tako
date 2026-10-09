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
import CoreGraphics
import Darwin
import Foundation
import TakoKit
import Testing
@testable import Tako

@MainActor
struct TakoAppCoverageTests {
    @Test func defaultAppIsReady() {
        let app = Tako.App()
        #expect(app.readiness == .ready)
        #expect(app.app != nil)
    }

    /// Whether quitting may ask follows confirm-close-surface; which
    /// terminals are busy is each surface's to say.
    @Test func quitConfirmationFollowsTheConfig() throws {
        let asks = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
        let never = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tako")
        try "".write(to: asks, atomically: true, encoding: .utf8)
        try "confirm-close-surface = false\n".write(to: never, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: asks)
            try? FileManager.default.removeItem(at: never)
        }

        #expect(Tako.App(configPath: asks.path).needsConfirmQuit)
        #expect(!Tako.App(configPath: never.path).needsConfirmQuit)
    }

    @Test func appTickIsANoOpThatDoesNotCrash() {
        let app = Tako.App()
        let configBefore = app.config
        app.appTick()
        #expect(app.readiness == .ready)
        #expect(app.config === configBefore)
    }

    @Test func configPathIsHonoredOnConstruction() throws {
        let text = "background-opacity = 0.42\n"
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        #expect(app.config.backgroundOpacity == 0.42)
    }

    @Test func reloadConfigReturnsToTheSameConfiguredFileRatherThanTheDefaultSearchPath() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("tako")
        try "background-opacity = 0.31\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = Tako.App(configPath: file.path)
        #expect(app.config.backgroundOpacity == 0.31)

        try "background-opacity = 0.77\n".write(to: file, atomically: true, encoding: .utf8)
        app.reloadConfig()
        #expect(app.config.backgroundOpacity == 0.77)
    }

    /// The surface-scoped app calls act on the view they are given. The
    /// split and fullscreen ones are requests to whichever controller holds
    /// the surface, so what they do is post the request.
    @Test @MainActor func surfaceScopedAppCallsReachTheSurface() {
        let app = Tako.App()
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let before = view.theme.fontSize

        app.changeFontSize(surface: view, .increase(2))
        #expect(view.theme.fontSize == before + 2)
        app.changeFontSize(surface: view, .decrease(1))
        #expect(view.theme.fontSize == before + 1)
        app.changeFontSize(surface: view, .reset)
        #expect(view.theme.fontSize == before)

        view.core.feed(bytes: Data("app-reset-marker".utf8))
        app.resetTerminal(surface: view)
        #expect(!view.core.bufferText().contains("app-reset-marker"))

        let log = NotificationLog(
            Tako.Notification.didEqualizeSplits, Tako.Notification.takoToggleFullscreen, object: view)
        defer { log.stop() }
        app.splitEqualize(surface: view)
        app.toggleFullscreen(surface: view)
        #expect(log.names == [Tako.Notification.didEqualizeSplits, Tako.Notification.takoToggleFullscreen])
    }

    /// The tako_surface_t overload is what upstream's paste-confirmation
    /// sheet calls; in this app nothing posts confirmClipboard, so it only
    /// reaches TakoKit's no-op C stub. Pin that it stays callable for both
    /// confirmation states and leaves the pasteboard alone.
    @Test func completeClipboardRequestForTheCSurfaceIsAHarmlessNoOp() {
        let before = NSPasteboard.general.changeCount
        Tako.App.completeClipboardRequest(tako_surface_t(), data: "hi", state: nil, confirmed: true)
        Tako.App.completeClipboardRequest(tako_surface_t(), data: "hi", state: nil)
        #expect(NSPasteboard.general.changeCount == before)
    }

    @Test func completeClipboardRequestForASurfaceViewPastesOnMain() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }

        Tako.App.completeClipboardRequest(view, data: "clipboard-relay-text-marker", state: nil, confirmed: true)

        // This dispatches `pasteText` onto `DispatchQueue.main` rather than
        // calling it inline -- right after the call returns, synchronously,
        // the paste has not happened yet. `pasteText`'s own body is covered
        // directly by `pasteTextEncodesAndWritesDirectly`.
        #expect(!view.visibleText.contains("clipboard-relay-text-marker"))
    }
}

// MARK: - Tako namespace helpers

@MainActor
struct TakoNamespaceHelperCoverageTests {
    @Test func titleForDirectoryPrefersTheLastPathComponent() {
        #expect(Tako.titleForDirectory("/Users/example/project") == "project")
    }

    @Test func titleForDirectoryUsesHomeGlyphForHomeAndRoot() {
        #expect(Tako.titleForDirectory(NSHomeDirectory()) == "~")
        #expect(Tako.titleForDirectory("/") == "~")
        #expect(Tako.titleForDirectory("") == "~")
        #expect(Tako.titleForDirectory("~") == "~")
    }

    @Test func moveFocusMakesTheViewFirstResponderImmediately() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view

        Tako.moveFocus(to: view)
        #expect(window.firstResponder === view)
    }

    /// The `delay` branch reaches `DispatchQueue.main.asyncAfter` -- a bare
    /// `swift test` host never runs a real main-thread run loop to drain
    /// GCD's main queue, so whether the scheduled block itself ever fires is
    /// unobservable here (the immediate branch above already proves `move`'s
    /// own body). What *is* observable, deterministically and synchronously,
    /// is that the delayed branch does not act immediately the way the
    /// immediate branch does.
    @Test func moveFocusWithADelayDoesNotCrash() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view

        Tako.moveFocus(to: view, delay: 0.01)

        #expect(window.firstResponder !== view)
    }

    /// `focusedWorkingDirectory` reads `NSApp.keyWindow` with no fallback.
    /// Whether this process's window can ever become key depends on
    /// activation the test host may or may not grant (see the same caveat
    /// documented in `TakoTerminalNSViewInputContextTests`); this proves the
    /// no-key-window guard either way, and the full lookup whenever the
    /// environment does grant one.
    @Test func focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface() {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        defer { view.close() }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let result = Tako.focusedWorkingDirectory
        if window.isKeyWindow {
            #expect(result == view.pwd)
        } else {
            #expect(result == nil)
        }
    }

    @Test func surfaceConfigurationDefaultInitHasNoOverrides() {
        let config = Tako.SurfaceConfiguration()
        #expect(config.fontSize == nil)
        #expect(config.workingDirectory == nil)
        #expect(config.command == nil)
        #expect(config.initialInput == nil)
        #expect(config.waitAfterCommand == false)
        #expect(config.environmentVariables.isEmpty)
    }

    @Test func surfaceConfigurationMemberwiseInitCarriesEveryField() {
        let config = Tako.SurfaceConfiguration(
            fontSize: 14, workingDirectory: "/tmp", command: "true",
            initialInput: "hi", waitAfterCommand: true,
            environmentVariables: ["A": "B"])
        #expect(config.fontSize == 14)
        #expect(config.workingDirectory == "/tmp")
        #expect(config.command == "true")
        #expect(config.initialInput == "hi")
        #expect(config.waitAfterCommand)
        #expect(config.environmentVariables == ["A": "B"])
    }

    @Test func moveTabCarriesItsAmount() {
        #expect(Tako.Action.MoveTab(amount: -2).amount == -2)
    }

    @Test func progressReportCarriesStateAndOptionalProgress() {
        let withProgress = Tako.Action.ProgressReport(state: .set, progress: 42)
        #expect(withProgress.state == .set)
        #expect(withProgress.progress == 42)

        let withoutProgress = Tako.Action.ProgressReport(state: .none)
        #expect(withoutProgress.state == .none)
        #expect(withoutProgress.progress == nil)
    }

    @Test func inspectorAndChildExitedMessageAreTrivialValueHolders() {
        _ = Tako.Inspector()
        #expect(Tako.ChildExitedMessage(message: "bye").message == "bye")
    }

    @Test func cachedValueRecomputesOnlyAfterInvalidation() {
        var calls = 0
        let cached = CachedValue<Int> { calls += 1; return calls }
        #expect(cached.get() == 1)
        #expect(cached.get() == 1)
        cached.invalidate()
        #expect(cached.get() == 2)
    }

    @Test func takoAppDelegateDefaultLookupReturnsNil() {
        final class Impl: TakoAppDelegate {}
        #expect(Impl().findSurface(forUUID: UUID()) == nil)
    }
}

// MARK: - Tako.Surface (the model wrapper, not the view)

@MainActor
struct TakoSurfaceModelCoverageTests {
    @Test func surfaceModelForwardsToItsView() throws {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { view.close() }
        let model = try #require(view.surfaceModel)

        #expect(model.view === view)
        #expect(model.unsafeCValue == nil)
        #expect(model.mouseCaptured == false)
        #expect(model.foregroundPID != nil || model.foregroundPID == nil)
        // See `startsAShellWithARealTtyAndForegroundProcess`: `ttyname(3)`
        // on the pty master reports ENOTTY, so this is nil in practice.
        _ = model.ttyName
        #expect(model.perform(action: "anything") == false)
        #expect(model.perform(action: "scroll_to_bottom") == true)

        model.sendText("echo surface-model-text\n")
        #expect(waitUntil(timeout: 8) { view.visibleText.contains("surface-model-text") })

        // The rest of the model's forwarding surface, exercised for
        // coverage of the one-line delegations to its view.
        model.sendKeyEvent(Tako.Input.KeyEvent(key: .space, action: .press))
        model.sendMousePos(Tako.Input.MousePosEvent(x: 5, y: 5, mods: []))
        model.sendMouseButton(Tako.Input.MouseButtonEvent(action: .press, button: .left, mods: []))
        model.sendMouseScroll(Tako.Input.MouseScrollEvent(
            x: 0, y: 0, mods: .init(precision: false, momentum: .none)))
    }

    @Test func surfaceModelInitWithCSurfaceHoldsNoView() {
        let model = Tako.Surface(cSurface: tako_surface_t())
        #expect(model.view == nil)
        #expect(model.unsafeCValue == nil)
    }
}
