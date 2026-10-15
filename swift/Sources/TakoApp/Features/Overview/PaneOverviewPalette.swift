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
    static let modalBackground = NSColor(srgbRed: 0x1A / 255, green: 0x15 / 255, blue: 0x12 / 255, alpha: 0.98)
    static let modalBorder = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
    static let cardBackground = NSColor(srgbRed: 0x1F / 255, green: 0x19 / 255, blue: 0x15 / 255, alpha: 1)
    static let selectedCardBackground = NSColor(srgbRed: 0x24 / 255, green: 0x1C / 255, blue: 0x16 / 255, alpha: 1)
    static let terminalBackground = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
    static let terminalText = NSColor(srgbRed: 0xED / 255, green: 0xE6 / 255, blue: 0xDF / 255, alpha: 1)
    static let activeText = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
    static let inactiveText = NSColor(srgbRed: 0xB7 / 255, green: 0xAC / 255, blue: 0xA1 / 255, alpha: 1)
    static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
    static let hairline = NSColor(srgbRed: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 1)
    static let searchBackground = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
    static let badge = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
    static let buttonBackground = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
    static let progressGradientStart = NSColor(srgbRed: 0xC2 / 255, green: 0x3E / 255, blue: 0x0E / 255, alpha: 1)
    static let progressGradientEnd = NSColor(srgbRed: 0xF4 / 255, green: 0x58 / 255, blue: 0x1C / 255, alpha: 1)
}
