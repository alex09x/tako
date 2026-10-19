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
import ObjectiveC
@testable import Tako

extension NSApplication {
    /// `terminate(_:)` in the test host, once `TerminalTestSupport.preventQuitting()` ran.
    @objc func takoTestHostTerminate(_ sender: Any?) {
        TerminalTestSupport.quitsPrevented += 1
    }
}

/// Shared helpers for the Terminal feature's behavioural coverage suites.
///
/// `Terminal.xib` (and its titlebar-style variants) are deliberately excluded
/// from this SwiftPM test target (see `swift/Package.swift`), so letting
/// `.window` load lazily via `windowNibName` would fail. Assigning `.window`
/// directly (mirroring `QTTestSupport.makeController`) short-circuits that
/// lazy path and lets us drive the real `windowDidLoad()` deliberately.
enum TerminalTestSupport {
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return condition() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Closing the last window quits (`quit-after-last-window-closed` is on
    /// by default), and in the test host a quit ends the whole run with the
    /// tests after it never run. It went unnoticed while closed tabs lingered
    /// as groups of their own, so no window was ever the last. Every helper
    /// that makes a terminal window turns that off first -- the last window
    /// then just closes -- and turns any quit that still comes, AppKit's own
    /// included, into a count.
    @MainActor static var quitsPrevented = 0
    @MainActor private static let quittingPrevented: Void = {
        guard let quit = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.terminate(_:))),
              let count = class_getInstanceMethod(
                NSApplication.self, #selector(NSApplication.takoTestHostTerminate(_:)))
        else { return }
        method_exchangeImplementations(quit, count)
    }()

    @MainActor static func preventQuitting() {
        TerminalController.lastWindowQuits = false
        _ = quittingPrevented
    }

    /// Builds a `TerminalController` with a real, manually constructed
    /// `TerminalWindow` attached directly (bypassing nib loading).
    @MainActor
    static func makeController(
        baseConfig: Tako.SurfaceConfiguration? = nil,
        surfaceTree: SplitTree<Tako.SurfaceView>? = nil
    ) -> (controller: TerminalController, window: TerminalWindow) {
        preventQuitting()
        let app = Tako.App()
        let controller = TerminalController(app, withBaseConfig: baseConfig, withSurfaceTree: surfaceTree)
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        return (controller, window)
    }

    /// Drives the real `windowDidLoad()` flow directly (as production would
    /// via the nib callback) without ever touching the excluded nib.
    @MainActor
    static func loaded(
        baseConfig: Tako.SurfaceConfiguration? = nil,
        surfaceTree: SplitTree<Tako.SurfaceView>? = nil
    ) -> (controller: TerminalController, window: TerminalWindow) {
        let (controller, window) = makeController(baseConfig: baseConfig, surfaceTree: surfaceTree)
        controller.windowDidLoad()
        return (controller, window)
    }

    @MainActor
    static func tearDown(_ controller: TerminalController, _ window: NSWindow) {
        window.orderOut(nil)
    }

    /// A `TerminalController.System` that attaches a real, manually
    /// constructed `TerminalWindow` (bypassing the excluded nib) and drives
    /// `windowDidLoad()`, mirroring `loaded()`. Installing this as
    /// `TerminalController.system` unblocks the window-dependent code in
    /// `newWindow`/`newTab`/undo-redo's `init(_:with:)` that would otherwise
    /// be permanently unreachable in this test host.
    @MainActor
    static func injectedWindowSystem() -> TerminalController.System {
        preventQuitting()
        return .init(attachWindow: { controller in
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            controller.window = window
            controller.windowDidLoad()
        })
    }

    /// Writes a config file with the given text and returns an app backed by it.
    /// The file is not automatically removed -- callers should clean it up.
    static func app(configText: String) throws -> (app: Tako.App, file: URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-\(UUID().uuidString).conf")
        try configText.write(to: file, atomically: true, encoding: .utf8)
        return (Tako.App(configPath: file.path), file)
    }
}
