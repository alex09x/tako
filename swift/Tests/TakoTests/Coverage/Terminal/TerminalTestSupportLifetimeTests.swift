/*
 * tako — Ownership of terminal-window test fixtures
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct TerminalTestSupportLifetimeTests {
    @Test func teardownRetiresOnlyItsOwnWindowAndPTYWhileReferencesRemain() throws {
        try #require(Tako.CustomTabGroup.suppressWindowOrderingForTesting)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tako-fixture-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config")
        try "session-persistence = false\nwindow-save-state = never\nauto-update = off\n"
            .write(to: config, atomically: true, encoding: .utf8)
        let oldConfig = getenv("TAKO_CONFIG_PATH").map { String(cString: $0) }
        setenv("TAKO_CONFIG_PATH", config.path, 1)
        defer {
            if let oldConfig { setenv("TAKO_CONFIG_PATH", oldConfig, 1) }
            else { unsetenv("TAKO_CONFIG_PATH") }
            try? FileManager.default.removeItem(at: root)
        }
        var base = Tako.SurfaceConfiguration(
            workingDirectory: root.path,
            environmentVariables: ["HOME": root.path, "XDG_CONFIG_HOME": root.path,
                                   "XDG_DATA_HOME": root.path, "XDG_CACHE_HOME": root.path,
                                   "HISTFILE": root.appendingPathComponent("history").path,
                                   "ZDOTDIR": root.path, "TAKO_AGENT_HOOKS_HOME": root.path,
                                   "CODEX_HOME": root.path])
        base.program = ["/bin/sleep", "60"]
        base.allowsSessionPersistence = false
        let (controller, window) = TerminalTestSupport.loaded(baseConfig: base)
        let (otherController, otherWindow) = TerminalTestSupport.loaded(baseConfig: base)
        // Explicit fallback cleanup keeps even the red run confined to its own fixtures.
        defer {
            for (owner, ownedWindow) in [(controller, window), (otherController, otherWindow)] {
                owner.cancelPendingInitialPresentation()
                owner.surfaceTree.forEach { $0.pty?.terminate() }
                Tako.CustomTabGroup.close(ownedWindow)
                ownedWindow.close()
                ownedWindow.contentView = nil
                ownedWindow.windowController = nil
            }
        }
        let surface = try #require(controller.surfaceTree.first)
        let otherSurface = try #require(otherController.surfaceTree.first)
        let pty = try #require(surface.pty)
        let otherPTY = try #require(otherSurface.pty)
        #expect(pty.alive && otherPTY.alive)
        #expect(window.contentView != nil)
        #expect(TerminalController.all.contains { $0 === controller })

        TerminalTestSupport.tearDown(controller, window)

        #expect(window.contentView == nil, "hidden hosting views must not keep publishing into later tests")
        #expect(!TerminalController.all.contains { $0 === controller }, "a torn-down fixture is not a live tab")
        #expect(!pty.alive, "the fixture's shell must not consume a PTY until the entire suite ends")
        #expect(TerminalController.all.contains { $0 === otherController })
        #expect(otherWindow.contentView != nil)
        #expect(otherPTY.alive, "cleanup must not stop another fixture")
    }
}
