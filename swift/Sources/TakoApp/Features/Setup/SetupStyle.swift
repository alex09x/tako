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

struct SetupButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(primary ? SetupStyle.background : SetupStyle.text)
            .background(primary ? SetupStyle.accent.opacity(configuration.isPressed ? 0.7 : 1)
                        : Color.white.opacity(configuration.isPressed ? 0.09 : 0.04), in: .rect(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(primary ? Color.clear : SetupStyle.border))
    }
}

struct SetupCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(SetupStyle.card, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SetupStyle.border))
    }
}

struct SetupBadge: View {
    let text: String
    var ready = false
    var body: some View {
        Label(text, systemImage: ready ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(ready ? SetupStyle.success : SetupStyle.muted)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((ready ? SetupStyle.success : SetupStyle.muted).opacity(0.08), in: .capsule)
    }
}
