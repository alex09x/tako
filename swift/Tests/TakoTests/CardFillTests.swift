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
import Testing
@testable import Tako

/// The card's margin round its terminal is filled with the background the
/// terminal is drawn in, so it reads as terminal rather than as a frame.
@MainActor @Suite
struct CardFillTests {
    @Test func theCardIsFilledWithTheThemeTheTerminalIsDrawnIn() throws {
        // The config's background differs from the theme the pane shows, as on
        // the owner's Mac: #14100e against a theme whose background is #0e1820.
        let (app, file) = try TerminalTestSupport.app(configText: "background = #14100e")
        defer { try? FileManager.default.removeItem(at: file) }
        let surface = Tako.SurfaceView(app)
        var theme = surface.theme
        theme.background = CGColor(srgbRed: 0x0e / 255, green: 0x18 / 255, blue: 0x20 / 255, alpha: 1)
        surface.applyTheme(theme)

        let fill = FloatingPaneGeometry.cardFill(for: surface)
        #expect(fill == surface.theme.background, "the card takes the terminal's own background")
        let config = NSColor(surface.derivedConfig.backgroundColor).usingColorSpace(.sRGB)
        let drawn = NSColor(cgColor: fill)?.usingColorSpace(.sRGB)
        #expect(config != drawn, "the fixture really has two different backgrounds")
    }
}
