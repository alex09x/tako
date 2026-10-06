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

import Testing
import AppKit
import UserNotifications
@testable import Tako

/// `AppDelegate` talks to a pure-stub `TakoKit` in this SwiftPM target (every
/// `tako_app_*`/`tako_config_*` C entry point is a no-op defined in
/// `TakoKit.swift`, not a real FFI bridge -- see that file), so constructing
/// a real `AppDelegate()` and driving its `NSApplicationDelegate` callbacks
/// directly is safe: nothing here reaches a real Rust core, a real Accessibility
/// prompt, or a modal alert (`needsConfirmQuit` is hard-coded `false`, so
/// `applicationShouldTerminate` always resolves via its early `.terminateNow`
/// paths and never reaches the confirmation alert in `terminate()`).
///
/// Two things are deliberately NOT exercised here even though they're
/// reachable from `AppDelegate`: `showAbout`/`toggleQuickTerminal` both lazily
/// load a nib (`About.xib`/`QuickTerminal.xib`) that this SwiftPM target
/// excludes (see swift/Package.swift), and `openConfig`/`showHelp`/
/// `setAsDefaultTerminal` launch a real external app or touch real Launch
/// Services defaults on the host running this suite.
@MainActor
func installDelegate(_ delegate: AppDelegate) -> NSApplicationDelegate? {
    _ = NSApplication.shared
    let original = NSApplication.shared.delegate
    NSApplication.shared.delegate = delegate
    return original
}

@MainActor
func restoreDelegate(_ original: NSApplicationDelegate?) {
    NSApplication.shared.delegate = original
}

/// A delegate whose alerts and termination replies never reach AppKit: a
/// modal alert never returns in a test host, and a real yes to a pending
/// termination ends the process. Busy terminal windows other tests left
/// open can lead any quit here into the confirmation path.
@MainActor
func quietDelegate(answer: NSApplication.ModalResponse = .alertThirdButtonReturn) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.runModalAlert = { _ in answer }
    delegate.replyToTermination = { _ in }
    return delegate
}

/// Terminal windows in this process that would ask before closing.
@MainActor
func busyTerminalWindows() -> [BaseTerminalController] {
    NSApplication.shared.windows
        .compactMap { $0.windowController as? BaseTerminalController }
        .filter { !$0.windowCanBeClosedWithoutConfirmation() }
}

/// Builds a real `TerminalController` with its window assigned directly
/// (bypassing nib loading, which would fail: `Terminal.xib` is excluded from
/// this SwiftPM target -- see swift/Package.swift), mirroring
/// `QTTestSupport.makeController`'s approach for `QuickTerminalController`.
@MainActor
func makeTerminalController(_ tako: Tako.App) -> (TerminalController, NSWindow) {
    let controller = TerminalController(tako)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    controller.window = window
    return (controller, window)
}

@MainActor
