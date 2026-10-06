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

import AppKit
import CoreGraphics
import Darwin
import Foundation
import TakoKit
import Testing
@testable import Tako

/// Exercises the surface/app adapter over the Rust core (`Tako+App.swift`):
/// the `PTY` wrapper, `Tako.App`'s stubbed lifecycle surface, and
/// `Tako.SurfaceView`'s own code -- everything that is not already covered
/// by `MetalTerminalHostTests` (the GPU-host pure functions) or
/// `AppReloadTests` (config reload, PTY environment).
///
/// `SurfaceView` spins up a real PTY and a real login shell, the same way
/// the app itself does; there is no seam to fake the shell out from under
/// it, and the shim's own self-tests (`runKeySelfTest` etc.) are written
/// the same way. Waits on shell output poll a condition with a deadline
/// instead of sleeping a fixed amount.
func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return true
}

