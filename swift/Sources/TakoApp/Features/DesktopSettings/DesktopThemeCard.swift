/*
 * tako — Desktop settings theme previews: catalog card and the large sample
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI
import TakoCoreUI

/// Facts a card shows about one preset, parsed once per catalog refresh.
struct DesktopThemeFacts: Equatable {
    let name: String
    let isUser: Bool
    let theme: TerminalTheme
    let uses: Int

    static func == (a: Self, b: Self) -> Bool { a.name == b.name && a.isUser == b.isUser && a.uses == b.uses }

    var fontLine: String {
        let size = theme.fontSize.rounded() == theme.fontSize ? String(Int(theme.fontSize)) : String(Double(theme.fontSize))
        return "\(theme.fontFamily ?? TerminalAppearanceCatalog.defaultFont) \(size)"
    }

    var meta: String {
        var parts = [fontLine, isUser ? "Custom" : "Built-in"]
        if uses > 0 { parts.append("\(uses) \(Self.places(uses))") }
        return parts.joined(separator: " · ")
    }

    static func places(_ n: Int) -> String {
        n == 1 ? "place" : "places"
    }
}

private extension TerminalTheme {
    func ansi(_ index: Int) -> Color {
        index < palette.count ? palette[index].map { Color(cgColor: $0) } ?? Color(cgColor: foreground) : Color(cgColor: foreground)
    }
}

/// `.pf-tc`: mini terminal (72 pt), name, meta and ⋯. The card body is one
/// button (`DesktopTheme-<name>`) that selects the theme for the level.
struct DesktopThemeCard<Actions: View>: View {
    let facts: DesktopThemeFacts
    let selected: Bool
    let palette: DesktopPalette
    let select: () -> Void
    @ViewBuilder let menu: Actions

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    mini
                    VStack(alignment: .leading, spacing: 2) {
                        Text(facts.name).font(.system(size: DesktopMetrics.bodyFontSize, weight: .medium))
                            .foregroundStyle(Color(palette.text)).lineLimit(1)
                        Text(facts.meta).font(.system(size: 11)).foregroundStyle(Color(palette.muted))
                            .lineLimit(2).padding(.trailing, 24)
                    }
                    .padding(EdgeInsets(top: 0, leading: 6, bottom: 4, trailing: 6))
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(palette.panel)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color(palette.accentBright) : Color(palette.separator), lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("DesktopTheme-\(facts.name)")
            .accessibilityValue(selected ? "selected" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            menu.padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 8))
        }
    }

    private var mini: some View {
        let t = facts.theme
        let mono = Font.custom(t.fontFamily ?? "Menlo", size: 10)
        return VStack(alignment: .leading, spacing: 1) {
            (Text("~/tako").foregroundColor(t.ansi(6)).fontWeight(.medium)
                + Text(" ❯ ").foregroundColor(t.ansi(2)) + Text("mitts test").foregroundColor(Color(cgColor: t.foreground)))
            Text("47 passed").foregroundColor(Color(cgColor: t.foreground).opacity(0.7))
            HStack(spacing: 4) {
                Text("1 failed").foregroundColor(t.ansi(1))
                Rectangle().fill(Color(cgColor: t.cursorColor)).frame(width: 6, height: 11)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                ForEach([1, 2, 3, 4, 5, 6], id: \.self) { Capsule().fill(t.ansi($0)).frame(height: 3) }
            }
        }
        .font(mono).lineLimit(1)
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(cgColor: t.background)))
    }
}

/// `.pf-pv`: the large sample of what this level renders right now.
struct DesktopTerminalPreview: View {
    let title: String
    let theme: TerminalTheme

    var body: some View {
        let t = theme
        let fg = Color(cgColor: t.foreground)
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 10.66)).foregroundStyle(fg.opacity(0.55)).padding(.bottom, 4)
            Group {
                (Text("~/tako").foregroundColor(t.ansi(6)) + Text(" main ±2").foregroundColor(t.ansi(5))
                    + Text(" ❯ ").foregroundColor(t.ansi(2)) + Text("mitts test -p auth").foregroundColor(fg))
                (Text("⚡ Mitts Build  ").foregroundColor(fg.opacity(0.6)) + Text("test [dev]").foregroundColor(fg.opacity(0.6)))
                (Text("test jwt::verify ... ").foregroundColor(fg) + Text("ok").foregroundColor(t.ansi(2)))
                (Text("test jwt::refresh ... ").foregroundColor(fg) + Text("FAILED").foregroundColor(t.ansi(1)))
                HStack(spacing: 0) {
                    Text("warning").foregroundColor(t.ansi(3))
                    Text(": unused import ").foregroundColor(fg)
                    Text("std::fmt").foregroundColor(fg).background(Color(cgColor: t.selectionBackground))
                    Text(" ")
                    Rectangle().fill(Color(cgColor: t.cursorColor)).frame(width: 8, height: 15)
                }
            }
            .font(.custom(t.fontFamily ?? "Menlo", size: DesktopMetrics.bodyFontSize))
            .lineSpacing(6.5)
            HStack(spacing: 4) {
                ForEach(0..<16, id: \.self) { i in RoundedRectangle(cornerRadius: 1.5).fill(t.ansi(i)).frame(width: 14, height: 5) }
            }
            .padding(.top, 8).padding(.leading, 20)
        }
        .lineLimit(1)
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(cgColor: t.background)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06)))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("DesktopThemePreview")
        .accessibilityLabel(title)
    }
}
