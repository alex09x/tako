/*
 * tako — Theme draft editor with live preview, save and cancel
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

struct DesktopThemeDraftEditor: View {
    @ObservedObject var model: DesktopSettingsModel
    let palette: DesktopPalette

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 12) {
                Text(draft.original.isUser ? "Изменение темы" : "Новая тема на основе «\(draft.original.name)»")
                    .font(.system(size: DesktopMetrics.titleFontSize, weight: .semibold))
                TextField("Theme name", text: Binding(get: { draft.name }, set: { v in model.updateDraft { $0.name = v } }))
                    .textFieldStyle(.roundedBorder)
                HStack(alignment: .top, spacing: 16) {
                    ScrollView { fields(draft) }.frame(width: 360)
                    preview(draft.preview(dark: DesktopPresentation.shared.isDark))
                }
                if let error = model.draftError {
                    Text(error).foregroundStyle(Color(palette.accent)).lineLimit(3)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelDraft() }.keyboardShortcut(.cancelAction)
                    Button("Сохранить") { model.saveDraft() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(DesktopMetrics.contentInset)
            .frame(width: 760, height: 560)
        }
    }

    @ViewBuilder private func fields(_ draft: DesktopThemeDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DesktopThemeDraft.colorKeys, id: \.self) { key in
                field(key, draft.value(key) ?? "") { v in model.updateDraft { $0.set(key, v.isEmpty ? nil : v) } }
            }
            Text("ANSI 16").font(.system(size: 11, weight: .semibold)).padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84)), count: 4), spacing: 6) {
                ForEach(0..<16, id: \.self) { index in
                    DesktopColorField(value: draft.paletteColor(index) ?? "") { v in
                        model.updateDraft { $0.setPalette(index, v.isEmpty ? nil : v) }
                    }.help("palette \(index)")
                }
            }
            Text("Font").font(.system(size: 11, weight: .semibold)).padding(.top, 6)
            ForEach(DesktopThemeDraft.faceKeys, id: \.self) { key in
                Picker(key, selection: Binding(get: { draft.value(key) ?? "" },
                                               set: { v in model.updateDraft { $0.set(key, v.isEmpty ? nil : v) } })) {
                    Text("Default").tag("")
                    ForEach(model.fonts, id: \.self) { Text($0).tag($0) }
                }
            }
            field("font-size", draft.value("font-size") ?? "") { v in
                model.updateDraft { if !$0.setFontSize(Double(v) ?? -1) { $0.set("font-size", nil) } }
            }
            ForEach(["font-thicken", "cursor-style", "cursor-style-blink"], id: \.self) { key in
                field(key, draft.value(key) ?? "") { v in model.updateDraft { $0.set(key, v.isEmpty ? nil : v) } }
            }
        }
    }

    private func field(_ key: String, _ value: String, commit: @escaping (String) -> Void) -> some View {
        HStack {
            Text(key).frame(width: 150, alignment: .leading)
            DesktopDraftTextField(value: value, commit: commit)
        }.frame(height: DesktopMetrics.controlHeight)
    }

    private func preview(_ theme: TerminalTheme) -> some View {
        let size = max(6, min(72, theme.fontSize))
        let font = Font.custom(theme.fontFamily ?? model.fallbackFontFamily, size: size)
        return VStack(alignment: .leading, spacing: 2) {
            Text("~/project $ mitts status").foregroundStyle(Color(cgColor: theme.foreground))
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle().fill(theme.palette[i].map { Color(cgColor: $0) } ?? .clear).frame(width: 18, height: 12)
                }
            }
            Text("mitts run").padding(.horizontal, 2)
                .background(Color(cgColor: theme.selectionBackground))
                .foregroundStyle(Color(cgColor: theme.foreground))
        }
        .font(font)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DesktopMetrics.panelRadius).fill(Color(cgColor: theme.background)))
    }
}

struct DesktopDraftTextField: View {
    let value: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text).textFieldStyle(.roundedBorder)
            .onSubmit { commit(text.trimmingCharacters(in: .whitespaces)) }
            .onAppear { text = value }.onChange(of: value) { text = $0 }
    }
}
