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

enum PaneOverviewPalette {
    static let modalBackground = NSColor(srgbRed: 0x1A / 255, green: 0x16 / 255, blue: 0x14 / 255, alpha: 0.98)
    static let modalBorder = NSColor(srgbRed: 0x36 / 255, green: 0x30 / 255, blue: 0x2B / 255, alpha: 1)
    static let cardBackground = NSColor(srgbRed: 0x22 / 255, green: 0x1D / 255, blue: 0x1A / 255, alpha: 1)
    static let terminalBackground = NSColor(srgbRed: 0x12 / 255, green: 0x0F / 255, blue: 0x0D / 255, alpha: 1)
    static let terminalText = NSColor(srgbRed: 0xD6 / 255, green: 0xCF / 255, blue: 0xC7 / 255, alpha: 1)
    static let activeText = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
    static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
    static let hairline = NSColor(srgbRed: 0x2E / 255, green: 0x28 / 255, blue: 0x24 / 255, alpha: 1)
    static let searchBackground = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
    static let badge = NSColor(srgbRed: 0x2D / 255, green: 0x26 / 255, blue: 0x22 / 255, alpha: 1)
    static let buttonBackground = NSColor(srgbRed: 0x2D / 255, green: 0x26 / 255, blue: 0x22 / 255, alpha: 1)
}
