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
@testable import TakoKit

import Testing
import AppKit
@testable import Tako
@testable import TakoKit

/// Additional coverage for `TerminalController` beyond
/// `TerminalControllerCoverageTests`: the window-creation paths
/// (`newWindow`, `newWindow(tree:)`, `newTab`) that need `.window` non-nil,
/// undo/redo bodies, and notification handlers' "match" branches.
///
/// `Terminal.xib` is excluded from this SwiftPM test target, so any code
/// that reads `.window` on a controller built the normal way is
/// unreachable. `TerminalController.system.attachWindow` is the injectable
/// seam that unblocks it: tests install `TerminalTestSupport.injectedWindowSystem()`
/// to attach a real, manually built `TerminalWindow` (mirroring
/// `TerminalTestSupport.makeController`) the moment a new controller is
/// created inside these methods.
@MainActor
func withInjectedWindowSystem<T>(_ body: () throws -> T) rethrows -> T {
    let original = TerminalController.system
    TerminalController.system = TerminalTestSupport.injectedWindowSystem()
    defer { TerminalController.system = original }
    return try body()
}

@MainActor
func withInjectedWindowSystem<T>(_ body: () async throws -> T) async rethrows -> T {
    let original = TerminalController.system
    TerminalController.system = TerminalTestSupport.injectedWindowSystem()
    defer { TerminalController.system = original }
    return try await body()
}

@MainActor
func withRealAppDelegate<T>(_ body: (AppDelegate) throws -> T) rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try body(appDelegate)
}

@MainActor
func withRealAppDelegate<T>(_ body: (AppDelegate) async throws -> T) async rethrows -> T {
    let appDelegate = AppDelegate()
    let originalDelegate = NSApplication.shared.delegate
    NSApplication.shared.delegate = appDelegate
    defer { NSApplication.shared.delegate = originalDelegate }
    return try await body(appDelegate)
}
