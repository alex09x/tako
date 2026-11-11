/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// `sidebar-style` as the design draws it (`.sbs-pick`): three small
/// previews of the sidebar, the chosen one outlined. It writes the same
/// setting, through the same store, as any registry row.
/// Accessibility: `DesktopSetting-sidebar-style-<value>`.
struct DesktopSidebarStylePicker: View {
    @ObservedObject var preferences: DesktopPreferenceStore
    let palette: DesktopPalette
    private let key = "sidebar-style"

    var body: some View {
        let copy = DesktopSettingCopy.of(key)
        let chosen = SidebarStyle(rawValue: preferences.value(key)) ?? .classic
        VStack(alignment: .leading, spacing: 10) {
            DesktopPrefRow(title: copy?.title ?? "Sidebar style", detail: copy?.detail ?? "",
                           key: "\(key) · immediately", palette: palette) {
                if preferences.isOverridden(key) {
                    Button { preferences.reset(key) } label: { Text("↺") }
                        .buttonStyle(.plain).foregroundStyle(Color(palette.muted))
                        .help("Restore Default")
                        .accessibilityIdentifier("DesktopSettingReset-\(key)")
                }
            }
            HStack(spacing: 8) {
                ForEach(SidebarStyle.allCases, id: \.self) { style in
                    card(style, label: copy?.options.first { $0.value == style.rawValue }?.label ?? style.rawValue,
                         isOn: style == chosen)
                }
            }
        }
        .id(DesktopRegistryRow.identifier(key))
    }

    private func card(_ style: SidebarStyle, label: String, isOn: Bool) -> some View {
        Button { preferences.set(key, style.rawValue) } label: {
            VStack(alignment: .leading, spacing: 6) {
                preview(style)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(isOn ? palette.text : palette.secondary))
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(isOn ? Color(palette.hover) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isOn ? Color(palette.accent) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("DesktopSetting-\(key)-\(style.rawValue)")
        .accessibilityLabel("\(label) sidebar")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// The style in miniature: the open session as an accent bar, then
    /// quieter ones, at the style's density.
    private func preview(_ style: SidebarStyle) -> some View {
        let (gap, bar, width): (CGFloat, CGFloat, CGFloat) = switch style {
        case .classic: (3, 5, 1)
        case .minimal: (6, 4, 0.7)
        case .compact: (2, 3, 1)
        }
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<4, id: \.self) { i in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: bar / 2)
                        .fill(Color(i == 0 ? palette.accent : palette.separator))
                        .frame(width: geo.size.width * (i == 0 ? 0.6 : width))
                }
                .frame(height: bar)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(palette.background)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(palette.border), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
