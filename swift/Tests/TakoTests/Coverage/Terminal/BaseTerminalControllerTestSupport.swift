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

@MainActor
func makeSurfaceView() -> Tako.SurfaceView {
    Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
}

@MainActor
func makeController(view: Tako.SurfaceView? = nil) -> BaseTerminalController {
    let v = view ?? makeSurfaceView()
    return BaseTerminalController(Tako.App(), surfaceTree: .init(view: v))
}

/// `BaseTerminalController` has no nib name of its own (`NSWindowController`
/// defaults it to nil), so assigning `.window` directly is safe and never
/// touches nib loading at all -- simpler than the `Terminal.xib`-exclusion
/// workaround `TerminalTestSupport` needs for the concrete subclass.
@MainActor
func makeControllerWithWindow(view: Tako.SurfaceView? = nil) -> (BaseTerminalController, NSWindow) {
    let controller = makeController(view: view)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false)
    controller.window = window
    return (controller, window)
}

@MainActor
