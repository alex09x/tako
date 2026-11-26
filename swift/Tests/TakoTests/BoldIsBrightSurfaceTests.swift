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

/// `bold-is-bright` from the config reaches the engine a pane draws from:
/// at creation, and when a theme is applied later. Without it a pane draws
/// bold text in the colour the program named.
@MainActor @Suite
struct BoldIsBrightSurfaceTests {
    private static let palette = "palette = 1=#a00000\npalette = 9=#102030\n"
    /// Bold red, then plain red.
    private static let output = Data("\u{1b}[1;31mA\u{1b}[22;31mB\u{1b}[0m".utf8)

    private func foreground(_ surface: Tako.SurfaceView, col: UInt32) -> [UInt8] {
        guard let cell = surface.core.getCell(row: 0, col: col) else { return [] }
        return [cell.fgR, cell.fgG, cell.fgB]
    }

    @Test func offByDefaultBoldKeepsTheColourTheProgramNamed() throws {
        let (app, file) = try TerminalTestSupport.app(configText: Self.palette)
        defer { try? FileManager.default.removeItem(at: file) }
        let surface = Tako.SurfaceView(app)
        #expect(surface.theme.boldIsBright == false)
        surface.feed(data: Self.output)
        #expect(foreground(surface, col: 0) == [0xA0, 0x00, 0x00])
        #expect(foreground(surface, col: 1) == [0xA0, 0x00, 0x00])
    }

    @Test func theConfigTurnsBoldBasicColoursBright() throws {
        let (app, file) = try TerminalTestSupport.app(configText: Self.palette + "bold-is-bright = true")
        defer { try? FileManager.default.removeItem(at: file) }
        let surface = Tako.SurfaceView(app)
        surface.feed(data: Self.output)
        #expect(foreground(surface, col: 0) == [0x10, 0x20, 0x30], "bold red draws as palette 9")
        #expect(foreground(surface, col: 1) == [0xA0, 0x00, 0x00], "plain red stays palette 1")
    }

    @Test func applyingAThemeSwitchesItBothWays() throws {
        let (app, file) = try TerminalTestSupport.app(configText: Self.palette)
        defer { try? FileManager.default.removeItem(at: file) }
        let surface = Tako.SurfaceView(app)
        surface.feed(data: Self.output)

        var theme = surface.theme
        theme.boldIsBright = true
        surface.applyTheme(theme)
        #expect(foreground(surface, col: 0) == [0x10, 0x20, 0x30])

        theme.boldIsBright = false
        surface.applyTheme(theme)
        #expect(foreground(surface, col: 0) == [0xA0, 0x00, 0x00])
    }
}
