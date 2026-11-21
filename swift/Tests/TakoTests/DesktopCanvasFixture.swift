/*
 * tako — A canvas fixture window that every test display can hold unclamped
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing

/// Hosted macOS runners have a 1024×768 display. A fixture window wider than
/// that is clamped by AppKit, and every expectation computed from the asked
/// width is then off by the clamp (224 pt with the sidebar). These fixtures
/// ask for a window that fits, and prove it was not clamped.
enum DesktopCanvasFixture {
    /// The whole window, sidebar included.
    static let windowWidth: CGFloat = 1000

    /// Records the display and the window actually given, and requires the
    /// asked width: a clamped window would make every frame check meaningless.
    @MainActor
    static func expectUnclamped(_ window: NSWindow, width: CGFloat,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        print("[canvas fixture] screen \(screen) window \(window.frame) content \(window.contentView?.bounds ?? .zero)")
        #expect(abs(window.frame.width - width) <= 0.5,
                "the fixture window was clamped: \(window.frame) on \(screen)", sourceLocation: sourceLocation)
    }
}
