/*
 * tako — Desktop settings rows bound to real registry keys
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// One registry setting: the reference's wording, the live value from the
/// config file, a control by type and ↺ when the file overrides the default.
/// Accessibility: `DesktopSetting-<key>` (segments append `-<value>`);
/// the interface scheme keeps `DesktopAppAppearance-<value>`.
struct DesktopRegistryRow: View {
    let key: String
    @ObservedObject var preferences: DesktopPreferenceStore
    let palette: DesktopPalette

    static func identifier(_ key: String) -> String {
        key == "app-appearance" ? "DesktopAppAppearance" : "DesktopSetting-\(key)"
    }

    var body: some View {
        if let item = DesktopPreferenceStore.item(key) {
            let copy = DesktopSettingCopy.of(key)
            DesktopPrefRow(title: copy?.title ?? item.title, detail: copy?.detail ?? item.description,
                           key: "\(item.id) · \(copy?.when ?? "immediately")", palette: palette) {
                HStack(spacing: 8) {
                    control(item, copy: copy)
                    if preferences.isOverridden(key) {
                        Button { preferences.reset(key) } label: { Text("↺") }
                            .buttonStyle(.plain).foregroundStyle(Color(palette.muted))
                            .help("Restore Default")
                            .accessibilityIdentifier("DesktopSettingReset-\(key)")
                    }
                }
            }
            .id(Self.identifier(key))
        }
    }

    @ViewBuilder private func control(_ item: TerminalSettingItem, copy: DesktopSettingCopy?) -> some View {
        let id = Self.identifier(key)
        switch item.type {
        case .boolean:
            DesktopToggle(isOn: preferences.bool(key), identifier: id, palette: palette) {
                preferences.set(key, $0 ? "true" : "false")
            }
        case .options(let options, _):
            let labelled: [(value: String, label: String)] =
                copy.map(\.options).flatMap { $0.isEmpty ? nil : $0 } ?? options.map { (value: $0, label: $0) }
            DesktopSegment(options: labelled, selection: preferences.value(key), identifier: id, palette: palette) {
                preferences.set(key, $0)
            }
        case .number(_, let min, let max, let step):
            DesktopStepper(value: Double(preferences.value(key)) ?? 0, range: Double(min)...Double(max),
                           step: Double(step), unit: copy?.unit ?? "", identifier: id, palette: palette) {
                preferences.set(key, DesktopStepper.render($0))
            }
        case .color:
            DesktopColorField(value: preferences.value(key), identifier: id, palette: palette) { preferences.set(key, $0) }
        }
    }
}

/// `.pf-step`: − value + with an editable number. Fractions are kept; out of
/// range input is refused by the store, not clamped here.
struct DesktopStepper: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    var unit = ""
    let identifier: String
    let palette: DesktopPalette
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    static func render(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    var body: some View {
        HStack(spacing: 4) {
            stepButton("−", identifier: "\(identifier)-decrease") { commit(max(range.lowerBound, value - step)) }
                .disabled(value <= range.lowerBound)
            TextField("", text: $text)
                .multilineTextAlignment(.center)
                .focused($focused)
                .frame(width: 56)
                .desktopField(palette, focused: focused)
                .accessibilityIdentifier(identifier)
                .onSubmit(submit)
                .onChange(of: focused) { _, now in if !now { submit() } }
            stepButton("+", identifier: "\(identifier)-increase") { commit(min(range.upperBound, value + step)) }
                .disabled(value >= range.upperBound)
            if !unit.isEmpty { Text(unit).foregroundStyle(Color(palette.muted)) }
        }
        .revealsWhenFocused(focused, id: identifier)
        .onAppear { text = Self.render(value) }
        .onChange(of: value) { _, new in text = Self.render(new) }
    }

    private func submit() {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(normalized) else { text = Self.render(value); return }
        if number != value { commit(number) }
    }

    private func stepButton(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(label).frame(width: 14) }
            .buttonStyle(DesktopButtonStyle(palette: palette))
            .accessibilityIdentifier(identifier)
    }
}

/// `.pf-color`: a swatch and the #rrggbb field.
struct DesktopColorField: View {
    let value: String
    let identifier: String
    let palette: DesktopPalette
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: NSColor(hex: value) ?? .clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(palette.border)))
                .frame(width: 28, height: 22)
            TextField("#rrggbb", text: $text)
                .font(.system(size: DesktopSettingsStyle.captionSize, design: .monospaced))
                .focused($focused)
                .frame(width: 72)
                .desktopField(palette, focused: focused)
                .accessibilityIdentifier(identifier)
                .onSubmit { commit(text.trimmingCharacters(in: .whitespaces)) }
        }
        .revealsWhenFocused(focused, id: identifier)
        .onAppear { text = value }
        .onChange(of: value) { _, new in text = new }
    }
}
