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
    let isDark: Bool

    init(theme: TerminalTheme) {
        let bg = NSColor(cgColor: theme.background)?.usingColorSpace(.sRGB) ?? Tako.Brand.surface
        let fg = NSColor(cgColor: theme.foreground) ?? Tako.Brand.text
        background = Color(nsColor: bg)
        text = Color(nsColor: fg)
        muted = text.opacity(0.65)
        accent = Color(nsColor: NSColor(cgColor: theme.cursorColor) ?? Tako.Brand.ember)
        success = Color(nsColor: theme.palette[2].flatMap { NSColor(cgColor: $0) } ?? Tako.Brand.ok)
        border = text.opacity(0.22)
        card = text.opacity(0.035)
        isDark = bg.redComponent * 0.2126 + bg.greenComponent * 0.7152 + bg.blueComponent * 0.0722 < 0.5
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
            .foregroundStyle(primary ? colors.background : colors.text)
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
    var body: some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(ready ? colors.success : colors.muted)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((ready ? colors.success : colors.muted).opacity(0.08), in: .capsule)
    }
}
