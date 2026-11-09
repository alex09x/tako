/*
 * tako — Terminal appearance: theme catalog, fonts and size per scope
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

struct DesktopAppearanceSection: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject var scope: DesktopScopeEditor
    @ObservedObject var themes: DesktopThemeLibrary
    let palette: DesktopPalette
    @State private var fontQuery = ""
    @State private var newName = ""
    @State private var renaming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            themeGroup
            fontGroup
            if !scope.isGlobal {
                Button("Сбросить все переопределения этого уровня") { scope.resetAll() }
            }
        }
    }

    private var selectedTheme: String? { scope.effectiveValue("theme") }

    private var themeGroup: some View {
        DesktopSettingsGroup(palette: palette) {
            DesktopSettingsRow(title: "Theme", detail: scope.sourceLabel("theme"), palette: palette) {
                if scope.source("theme") == .local {
                    Button("Наследовать") { scope.inherit("theme") }
                }
            }
            ForEach(themes.entries) { entry in themeRow(entry) }
            if let renaming {
                HStack {
                    TextField("New name", text: $newName).textFieldStyle(.roundedBorder)
                    Button("Rename") { themes.rename(renaming, to: newName); self.renaming = nil }
                        .disabled(newName.isEmpty)
                    Button("Cancel") { self.renaming = nil }
                }.padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    private func themeRow(_ entry: DesktopThemeLibrary.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selectedTheme == entry.name ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(Color(selectedTheme == entry.name ? palette.accent : palette.muted))
            Text(entry.name)
            if !entry.isUser {
                Text("Built-in").font(.system(size: 11)).foregroundStyle(Color(palette.muted))
            }
            Spacer()
            Button("Выбрать") { scope.selectPreset(entry.name) }.disabled(selectedTheme == entry.name)
            Menu {
                Button(entry.isUser ? "Edit…" : "Изменить копию…") { model.editTheme(entry.name) }
                Button("Дублировать") { themes.duplicate(entry.name, as: uniqueName(entry.name + " копия")) }
                if entry.isUser {
                    Button("Rename…") { renaming = entry.name; newName = entry.name }
                    Button("Удалить", role: .destructive) { themes.delete(entry.name) }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.horizontal, 14)
        .frame(height: DesktopMetrics.navigationRowHeight)
        .accessibilityIdentifier("theme-\(entry.name)")
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(themes.entries.map(\.name))
        var candidate = base
        var index = 2
        while names.contains(candidate) { candidate = "\(base) \(index)"; index += 1 }
        return candidate
    }

    private var fontGroup: some View {
        let resolution = model.fontResolution()
        return DesktopSettingsGroup(palette: palette) {
            DesktopSettingsRow(title: "Font", detail: scope.sourceLabel("font-family"), palette: palette) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(resolution.rendered)
                    if resolution.isFallback, let requested = resolution.requested {
                        Text("«\(requested)» не установлен — используется \(resolution.rendered)")
                            .font(.system(size: 11)).foregroundStyle(Color(palette.accent))
                    }
                }
            }
            DesktopSettingsRow(title: "Size", detail: "Сохранённый базовый размер; временное увеличение панели не сохраняется",
                               palette: palette) { sizeControl }
            TextField("Поиск шрифта", text: $fontQuery).textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14).padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredFonts, id: \.self) { family in fontRow(family, selected: family == resolution.requested) }
                }
            }.frame(height: 200)
        }
    }

    private var filteredFonts: [String] {
        let q = fontQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.fonts : model.fonts.filter { $0.lowercased().contains(q) }
    }

    private func fontRow(_ family: String, selected: Bool) -> some View {
        Button { scope.set("font-family", family) } label: {
            HStack {
                Text(family).frame(width: 180, alignment: .leading).lineLimit(1)
                Text("mitts run ~/project")
                    .font(.custom(family, size: DesktopMetrics.bodyFontSize)).foregroundStyle(Color(palette.secondary))
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color(palette.accent)) }
            }
            .padding(.horizontal, 14).frame(height: DesktopMetrics.navigationRowHeight).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var sizeControl: some View {
        let current = Double(scope.effectiveValue("font-size") ?? "") ?? 13
        return HStack(spacing: 6) {
            Stepper(String(format: current.rounded() == current ? "%.0f пт" : "%.1f пт", current),
                    value: Binding(get: { current }, set: { scope.set("font-size", Self.render($0)) }),
                    in: 6...72, step: 0.5)
            if scope.source("font-size") == .local {
                Button { scope.inherit("font-size") } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
            }
        }
    }

    static func render(_ size: Double) -> String {
        size.rounded() == size ? String(Int(size)) : String(size)
    }
}
