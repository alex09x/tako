/*
 * tako — Desktop settings theme editor: draft, live preview, five tabs
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// The reference's inline editor (pf-ed). Every edit goes to the draft and
/// the live preview; nothing is written until «Save Theme».
/// Accessibility: `DesktopThemeName`, `DesktopThemeBack`,
/// `DesktopThemeEditorSection-<tab>`, `DesktopThemeConfiguration`,
/// `DesktopThemeField-<key>`, `DesktopThemePalette-<n>`.
struct DesktopThemeDraftEditor: View {
    enum Tab: String, CaseIterable {
        case colors, ansi, type, cursor, config
        var title: String {
            switch self {
            case .colors: "Colors"
            case .ansi: "ANSI"
            case .type: "Font"
            case .cursor: "Cursor & Selection"
            case .config: "Configuration"
            }
        }
    }

    @ObservedObject var model: DesktopSettingsModel
    let palette: DesktopPalette
    @State private var tab: Tab = .colors
    @FocusState private var nameFocused: Bool

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 0) {
                header(draft)
                DesktopTerminalPreview(title: "\(draft.name) · \(DesktopAppearanceSection.fontLine(draft.preview(dark: TakoSystemAppearance.isDark)))",
                                       theme: draft.preview(dark: TakoSystemAppearance.isDark))
                    .padding(.top, 16)
                tabs.padding(.top, 16)
                tabBody(draft).padding(.top, 4)
            }
        }
    }

    private func header(_ draft: DesktopThemeDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 16) {
                Button("‹ Themes") { model.cancelDraft() }
                    .buttonStyle(.plain).padding(.horizontal, 8).frame(height: DesktopMetrics.controlHeight)
                    .accessibilityIdentifier("DesktopThemeBack")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Theme name").font(.system(size: 11.5)).foregroundStyle(Color(palette.muted))
                    TextField("", text: Binding(get: { draft.name }, set: { v in model.updateDraft { $0.name = v } }))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(palette.text))
                        .focused($nameFocused)
                        .desktopField(palette, focused: nameFocused, height: 32)
                        .accessibilityIdentifier("DesktopThemeName")
                    if let error = draft.nameError {
                        Text(error).font(.system(size: 11.5)).foregroundStyle(Color(palette.accentBright))
                    }
                }
            }
            Text(draft.isCopy ? "Copy of “\(draft.original.name)” — the original theme stays unchanged"
                              : "Custom theme — changes will be saved to its file")
                .font(.system(size: DesktopSettingsStyle.captionSize)).foregroundStyle(Color(palette.muted))
        }
        .onAppear { nameFocused = true }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { item in
                let on = item == tab
                Button { tab = item } label: {
                    Text(item.title).foregroundStyle(Color(on ? palette.text : palette.muted))
                        .padding(.horizontal, 12).frame(height: 32)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? Color(palette.accentBright) : .clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DesktopThemeEditorSection-\(item.rawValue)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color(palette.separator)).frame(height: 1) }
    }

    @ViewBuilder private func tabBody(_ draft: DesktopThemeDraft) -> some View {
        switch tab {
        case .colors:
            colorRow("Background", "background", draft)
            colorRow("Text", "foreground", draft)
            DesktopPrefRow(title: "Background opacity", detail: "1 means fully opaque", palette: palette) {
                DesktopStepper(value: Double(draft.value("background-opacity") ?? "1") ?? 1, range: 0...1, step: 0.05,
                               identifier: "DesktopThemeField-background-opacity", palette: palette) { v in
                    model.updateDraft { $0.set("background-opacity", v == 1 ? nil : DesktopStepper.render((v * 100).rounded() / 100)) }
                }
            }
        case .ansi:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 6) {
                ForEach(0..<16, id: \.self) { index in
                    HStack(spacing: 8) {
                        Text("\(index)").font(.system(size: DesktopSettingsStyle.keySize, design: .monospaced))
                            .foregroundStyle(Color(palette.faint)).frame(width: 18, alignment: .trailing)
                        DesktopColorField(value: draft.paletteColor(index) ?? "", identifier: "DesktopThemePalette-\(index)",
                                          palette: palette) { v in model.updateDraft { $0.setPalette(index, v.isEmpty ? nil : v) } }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 12)
        case .type:
            DesktopPrefRow(title: "Font", detail: "Fonts installed on this Mac", key: "font-family", palette: palette) {
                fontPicker("font-family", draft)
            }
            DesktopPrefRow(title: "Size", detail: "6–72 pt; fractional values are supported", key: "font-size", palette: palette) {
                DesktopStepper(value: Double(draft.value("font-size") ?? "13") ?? 13, range: 6...72, step: 0.5,
                               unit: "pt", identifier: "DesktopThemeField-font-size", palette: palette) { v in
                    model.updateDraft { _ = $0.setFontSize(v) }
                }
            }
            DesktopPrefRow(title: "Bold", key: "font-family-bold", palette: palette) { fontPicker("font-family-bold", draft) }
            DesktopPrefRow(title: "Italic", key: "font-family-italic", palette: palette) { fontPicker("font-family-italic", draft) }
        case .cursor:
            colorRow("Cursor", "cursor-color", draft)
            colorRow("Text Under Cursor", "cursor-text", draft)
            DesktopPrefRow(title: "Shape", key: "cursor-style", palette: palette) {
                DesktopSegment(options: [("block", "Block"), ("bar", "Bar"), ("underline", "Underline")],
                               selection: draft.value("cursor-style") ?? "block", identifier: "DesktopThemeField-cursor-style",
                               palette: palette) { v in model.updateDraft { $0.set("cursor-style", v) } }
            }
            colorRow("Selection Background", "selection-background", draft)
            colorRow("Selected Text", "selection-foreground", draft)
        case .config:
            DesktopThemeConfigText(text: draft.text, palette: palette) { v in model.updateDraft { $0.replaceText(v) } }
                .padding(.top, 12)
            if let error = draft.configError {
                Text(error).font(.system(size: DesktopSettingsStyle.captionSize)).foregroundStyle(Color(palette.accentBright))
                    .padding(.top, 6).accessibilityIdentifier("DesktopThemeConfigError")
            } else {
                DesktopHint(text: "Uses Tako configuration keys: background, foreground, palette = N=#RRGGBB, font-family, font-size, cursor-* and selection-*.",
                            palette: palette).padding(.top, 6)
            }
        }
    }

    private func colorRow(_ title: String, _ key: String, _ draft: DesktopThemeDraft) -> some View {
        DesktopPrefRow(title: title, key: key, palette: palette) {
            DesktopColorField(value: draft.value(key) ?? "", identifier: "DesktopThemeField-\(key)", palette: palette) { v in
                model.updateDraft { $0.set(key, v.isEmpty ? nil : v) }
            }
        }
    }

    private func fontPicker(_ key: String, _ draft: DesktopThemeDraft) -> some View {
        Picker("", selection: Binding(get: { draft.value(key) ?? "" }, set: { v in model.updateDraft { $0.set(key, v.isEmpty ? nil : v) } })) {
            Text("Same as Regular").tag("")
            ForEach(model.fonts, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().frame(width: 200)
        .accessibilityIdentifier("DesktopThemeField-\(key)")
    }
}

/// The «Configuration» tab: the exact text that will be saved.
struct DesktopThemeConfigText: View {
    let text: String
    let palette: DesktopPalette
    let commit: (String) -> Void
    @State private var local = ""

    var body: some View {
        TextEditor(text: $local)
            .font(.system(size: 11.5, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(palette.field)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(palette.separator)))
            .accessibilityIdentifier("DesktopThemeConfiguration")
            .onAppear { local = text }
            .onChange(of: local) { _, new in if new != text { commit(new) } }
            .onChange(of: text) { _, new in if new != local { local = new } }
    }
}

/// Footer while a draft is open: preview reach or what blocks saving.
struct DesktopThemeDraftFooter: View {
    @ObservedObject var model: DesktopSettingsModel
    let palette: DesktopPalette

    var body: some View {
        let draft = model.draft
        Group {
            if let error = model.draftError ?? (draft?.canSave == false ? "Fix the errors before saving the theme" : nil) {
                Text(error).foregroundStyle(Color(palette.accentBright)).accessibilityIdentifier("DesktopThemeError")
            } else {
                Text(previewLine).foregroundStyle(Color(palette.muted))
            }
        }
        .font(.system(size: DesktopSettingsStyle.captionSize)).lineLimit(2)
        Spacer(minLength: 0)
        Button("Undo") { model.cancelDraft() }
            .buttonStyle(DesktopButtonStyle(palette: palette))
            .accessibilityIdentifier("DesktopThemeCancel")
        Button("Save Theme") { model.saveDraft() }
            .buttonStyle(DesktopButtonStyle(primary: true, palette: palette))
            .disabled(draft?.canSave != true)
            .accessibilityIdentifier("DesktopThemeSave")
    }

    private var previewLine: String {
        let count = model.preview?.targetCount ?? 0
        let level = model.scope.isGlobal ? "all terminals" : "terminals in “\(model.scope.title)”"
        return count > 0 ? "Live preview on \(level) · \(count)" : "No open terminals available for live preview"
    }
}
