/*
 * tako — Desktop settings building blocks measured from the frozen reference
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Sizes taken from docs/design/desktop-reference (computed styles of the
/// published prototype at 1440×900, prefs.css / prefs-detail.css).
enum DesktopSettingsStyle {
    static let sidebarInsets = EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
    static let topInsets = EdgeInsets(top: 16, leading: 24, bottom: 8, trailing: 16)
    static let pageInsets = EdgeInsets(top: 16, leading: 24, bottom: 24, trailing: 24)
    static let footerInsets = EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 16)
    static let sidebarTitleSize: CGFloat = 15
    static let captionSize: CGFloat = 12
    static let keySize: CGFloat = 10.5
    static let rowGap: CGFloat = 16
    static let closeSize: CGFloat = 26
    static let segmentHeight: CGFloat = 24
    static let toggleSize = CGSize(width: 30, height: 18)
    /// The dim layer over the host while settings are open.
    static let scrim = NSColor(srgbRed: 10 / 255, green: 8 / 255, blue: 7 / 255, alpha: 0.08)
}

/// `.pf-blk`: a titled group of rows, 16 pt above and below.
struct DesktopBlock<Content: View>: View {
    let title: String
    var note: String?
    let palette: DesktopPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: DesktopMetrics.bodyFontSize, weight: .semibold))
                    .foregroundStyle(Color(palette.text))
                if let note {
                    Text(note).font(.system(size: DesktopSettingsStyle.captionSize))
                        .foregroundStyle(Color(palette.muted)).lineLimit(1)
                }
            }
            content
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `.pf-row`: title, what it does, the real config key and when it applies.
struct DesktopPrefRow<Control: View>: View {
    let title: String
    var detail: String?
    var key: String?
    let palette: DesktopPalette
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DesktopSettingsStyle.rowGap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: DesktopMetrics.bodyFontSize, weight: .medium))
                    .foregroundStyle(Color(palette.text))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: DesktopSettingsStyle.captionSize))
                        .foregroundStyle(Color(palette.muted)).fixedSize(horizontal: false, vertical: true)
                }
                if let key {
                    Text(key).font(.system(size: DesktopSettingsStyle.keySize, design: .monospaced))
                        .foregroundStyle(Color(palette.faint)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The control keeps its full width; the explanation wraps instead.
            control.layoutPriority(1)
        }
        .padding(.vertical, 10)
    }
}

/// `.pf-seg`: a field-coloured track with the chosen option raised.
struct DesktopSegment: View {
    let options: [(value: String, label: String)]
    let selection: String
    let identifier: String
    let palette: DesktopPalette
    let choose: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { choose(option.value) } label: {
                    // Each segment is its label's own width (reference: «While a command is running
                    // command» is wider than «Always»), never an equal truncated share.
                    Text(option.label).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(height: DesktopSettingsStyle.segmentHeight)
                        .foregroundStyle(Color(on ? palette.text : palette.secondary))
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color(palette.border) : .clear)
                            .shadow(color: on ? .black.opacity(0.25) : .clear, radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(identifier)-\(option.value)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(palette.field)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(palette.separator)))
        .fixedSize()
    }
}

/// `button.tg`: 30×18 capsule, accent when on, 14 pt knob.
struct DesktopToggle: View {
    let isOn: Bool
    let identifier: String
    let palette: DesktopPalette
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color(palette.accent).opacity(0.85) : Color(palette.border))
                Circle().fill(isOn ? Color(red: 250 / 255, green: 247 / 255, blue: 242 / 255)
                                   : Color(red: 138 / 255, green: 127 / 255, blue: 118 / 255))
                    .frame(width: 14, height: 14).padding(2)
            }
            .frame(width: DesktopSettingsStyle.toggleSize.width, height: DesktopSettingsStyle.toggleSize.height)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(.isButton)
    }
}

/// `.pf-btn` and `.pf-btn.pri`.
struct DesktopButtonStyle: ButtonStyle {
    var primary = false
    let palette: DesktopPalette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DesktopMetrics.bodyFontSize, weight: primary ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: DesktopMetrics.controlHeight)
            .foregroundStyle(primary ? Color(red: 26 / 255, green: 18 / 255, blue: 16 / 255) : Color(palette.secondary))
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius)
                .fill(Color(primary ? palette.accentBright : palette.raised)))
            .overlay(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius)
                .strokeBorder(primary ? .clear : Color(palette.border)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// `.pf-in`: 28 pt field, 7 pt radius, accent ring while focused.
struct DesktopFieldStyle: ViewModifier {
    let palette: DesktopPalette
    var focused = false
    var height: CGFloat = DesktopMetrics.controlHeight

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius).fill(Color(palette.field)))
            .overlay(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius)
                .strokeBorder(focused ? Color(palette.accentBright) : Color(palette.separator), lineWidth: focused ? 1.5 : 1))
    }
}

extension View {
    func desktopField(_ palette: DesktopPalette, focused: Bool = false, height: CGFloat = DesktopMetrics.controlHeight) -> some View {
        modifier(DesktopFieldStyle(palette: palette, focused: focused, height: height))
    }
}

/// `kbd`: one key of a shortcut, 22 pt tall.
struct DesktopKeyCap: View {
    let symbol: String
    let palette: DesktopPalette

    var body: some View {
        Text(symbol).font(.system(size: DesktopMetrics.bodyFontSize, weight: .medium))
            .foregroundStyle(Color(palette.text))
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(palette.field)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(palette.border)))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(Color(palette.border)).frame(height: 1).padding(.horizontal, 2)
            }
    }
}

/// `.pf-hint`: a muted paragraph inside a block.
struct DesktopHint: View {
    let text: String
    let palette: DesktopPalette

    var body: some View {
        Text(text).font(.system(size: DesktopSettingsStyle.captionSize))
            .lineSpacing(1.6)
            .foregroundStyle(Color(palette.muted))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
