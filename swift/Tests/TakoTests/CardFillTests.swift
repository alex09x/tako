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

    /// A colour the engine holds apart from the theme -- a program's OSC 11,
    /// or one a restored session carried -- is what the terminal is drawn in,
    /// and so what the card is filled with; a later theme does not move it.
    @Test func theCardFollowsTheBackgroundTheEngineDraws() throws {
        let (app, file) = try TerminalTestSupport.app(configText: "background = #14100e")
        defer { try? FileManager.default.removeItem(at: file) }
        let surface = Tako.SurfaceView(app)
        surface.core.feed(bytes: Data("\u{1b}]11;#0e1820\u{07}\u{1b}]10;#ede6df\u{07}".utf8))
        surface.terminalViewDidChangeContent(surface)
        var theme = surface.theme
        theme.background = rgb(0x282A36)
        theme.foreground = rgb(0xF8F8F2)
        surface.applyTheme(theme)

        #expect(surface.drawnColors.background == FfiRgb(r: 0x0E, g: 0x18, b: 0x20))
        #expect(FloatingPaneGeometry.cardFill(for: surface) == rgb(0x0E1820), "the drawn colour, not the theme's")
        let palette = CardHeaderPalette.of(surface)
        #expect(palette == CardHeaderPalette(background: rgb(0x0E1820), foreground: rgb(0xEDE6DF)))

        surface.core.feed(bytes: Data("\u{1b}]111\u{07}".utf8))
        surface.terminalViewDidChangeContent(surface)
        #expect(FloatingPaneGeometry.cardFill(for: surface) == rgb(0x282A36), "a reset program colour hands back to the theme")
    }

    private func rgb(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// The header sits on the terminal's background in the terminal's colours:
    /// readable for a light terminal in a dark shell, the reverse, and a
    /// foreground too close to its background -- whichever scheme the shell is in.
    @Test(arguments: [(UInt32(0xF4F1EA), UInt32(0x222222), true),   // light terminal
                      (UInt32(0x0E1820), UInt32(0xEDE6DF), false),  // dark terminal
                      (UInt32(0x222222), UInt32(0x333333), false),  // foreground lost in background
                      (UInt32(0xFFFFFF), UInt32(0x767676), true),   // a foreground just at the title bound
                      (UInt32(0x888888), UInt32(0x999999), false)]) // mid-grey: black reads better than white
    func theHeaderIsReadableOnTheTerminalsBackground(bg: UInt32, fg: UInt32, light: Bool) {
        let saved = Tako.LivingTokens.isLight
        defer { Tako.LivingTokens.isLight = saved }
        var palettes: [CardHeaderPalette] = []
        for shellIsLight in [false, true] {
            Tako.LivingTokens.isLight = shellIsLight
            palettes.append(CardHeaderPalette(background: rgb(bg), foreground: rgb(fg)))
        }
        #expect(palettes[0] == palettes[1], "the shell's scheme does not change a card's header")
        let p = palettes[0]
        #expect(p.isLight == light)
        #expect(p.contrast(of: p.title) >= 4.5, "title \(p.contrast(of: p.title)):1")
        #expect(p.contrast(of: p.secondary) >= 3, "secondary \(p.contrast(of: p.secondary)):1")
    }
}
