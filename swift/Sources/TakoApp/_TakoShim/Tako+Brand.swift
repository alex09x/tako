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

extension Tako {
    /// The brand palette.
    enum Brand {
        static let ember = NSColor(srgbRed: 0xF4 / 255, green: 0x58 / 255, blue: 0x1C / 255, alpha: 1)
        static let claw = NSColor(srgbRed: 0xFF / 255, green: 0x7A / 255, blue: 0x3D / 255, alpha: 1)
        static let rust = NSColor(srgbRed: 0xC2 / 255, green: 0x3E / 255, blue: 0x0E / 255, alpha: 1)
        static let ink = NSColor(srgbRed: 0x1A / 255, green: 0x15 / 255, blue: 0x12 / 255, alpha: 1)
        static let paper = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
        /// Terminal body and chrome, warm rather than blue.
        static let surface = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
        static let text = NSColor(srgbRed: 0xED / 255, green: 0xE6 / 255, blue: 0xDF / 255, alpha: 1)
        static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
        static let ok = NSColor(srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1)
        static let error = NSColor(srgbRed: 0xD5 / 255, green: 0x4E / 255, blue: 0x53 / 255, alpha: 1)

        static func color(for dot: String, active: Bool = true) -> NSColor {
            switch dot {
            case "ember": return ember
            case "ok": return ok
            case "claw": return claw
            case "error": return error
            case "dim": return dim
            default: return active ? ok : dim
            }
        }

        static func hexString(for color: NSColor) -> String {
            guard let rgb = color.usingColorSpace(.sRGB) else { return "#7bd88f" }
            let r = Int(round(rgb.redComponent * 255.0))
            let g = Int(round(rgb.greenComponent * 255.0))
            let b = Int(round(rgb.blueComponent * 255.0))
            return String(format: "#%02x%02x%02x", r, g, b)
        }

        static func hex(for dot: String, active: Bool = true) -> String {
            hexString(for: color(for: dot, active: active))
        }
    }
}
