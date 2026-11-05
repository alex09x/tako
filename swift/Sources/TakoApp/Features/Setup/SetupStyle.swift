/*
 * tako — Setup visual components
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

enum SetupStyle {
    static let background = Color(nsColor: Tako.Brand.surface)
    static let text = Color(nsColor: Tako.Brand.text)
    static let muted = Color(nsColor: Tako.Brand.dim)
    static let accent = Color(nsColor: Tako.Brand.ember)
    static let success = Color(nsColor: Tako.Brand.ok)
    static let border = Color(nsColor: Tako.Brand.dim).opacity(0.27)
    static let card = Color.white.opacity(0.025)
}

struct SetupPalette {
    let background: Color
    let text: Color
    let muted: Color
    let accent: Color
    let success: Color
    let border: Color
    let card: Color
    let primaryText: Color
    let message: Color
    let isDark: Bool

    init(theme: TerminalTheme) {
        let bg = NSColor(cgColor: theme.background)?.usingColorSpace(.sRGB) ?? Tako.Brand.surface
        let fg = NSColor(cgColor: theme.foreground) ?? Tako.Brand.text
        background = Color(nsColor: bg)
        text = Color(nsColor: fg)
        muted = text.opacity(0.65)
        let accentColor = NSColor(cgColor: theme.cursorColor) ?? Tako.Brand.ember
        accent = Color(nsColor: accentColor)
        primaryText = Color(nsColor: Self.readable(bg, against: accentColor))
        message = Color(nsColor: Self.readable(Tako.Brand.claw, against: bg))
        success = Color(nsColor: theme.palette[2].flatMap { NSColor(cgColor: $0) } ?? Tako.Brand.ok)
        border = text.opacity(0.22)
        card = text.opacity(0.035)
        isDark = bg.redComponent * 0.2126 + bg.greenComponent * 0.7152 + bg.blueComponent * 0.0722 < 0.5
    }

    private static func readable(_ preferred: NSColor, against background: NSColor) -> NSColor {
        if contrast(preferred, background) >= 4.5 { return preferred }
        return contrast(.black, background) >= contrast(.white, background) ? .black : .white
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB) ?? NSColor.black.usingColorSpace(.sRGB)!
            let components = [c.redComponent, c.greenComponent, c.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}

private struct SetupPaletteKey: EnvironmentKey {
    static let defaultValue = SetupPalette(theme: .takoDefault)
}

extension EnvironmentValues {
    var setupPalette: SetupPalette {
        get { self[SetupPaletteKey.self] }
        set { self[SetupPaletteKey.self] = newValue }
    }
}

struct SetupButtonStyle: ButtonStyle {
    @Environment(\.setupPalette) private var colors
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(primary ? colors.primaryText : colors.text)
            .background(primary ? colors.accent.opacity(configuration.isPressed ? 0.7 : 1)
                        : colors.text.opacity(configuration.isPressed ? 0.09 : 0.04), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(primary ? Color.clear : colors.border))
    }
}

struct SetupCard<Content: View>: View {
    @Environment(\.setupPalette) private var colors
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(colors.card, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(colors.border))
    }
}

struct SetupBadge: View {
    @Environment(\.setupPalette) private var colors
    let text: String
    var ready = false
    var showsSymbol = true
    var body: some View {
        HStack(spacing: 5) {
            if showsSymbol { Image(systemName: ready ? "checkmark.circle.fill" : "circle") }
            Text(text)
        }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(ready ? colors.success : colors.muted)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((ready ? colors.success : colors.muted).opacity(0.08), in: .capsule)
    }
}
