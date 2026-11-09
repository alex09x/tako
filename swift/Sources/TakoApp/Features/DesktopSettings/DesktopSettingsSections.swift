/*
 * tako — Native settings section bodies bound to the real registry
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

struct DesktopSettingsSectionBody: View {
    @ObservedObject var model: DesktopSettingsModel
    let palette: DesktopPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.section {
            case .general: general
            case .terminalAppearance: DesktopAppearanceSection(model: model, scope: model.scope,
                                                               themes: model.themes, palette: palette)
            case .keys: DesktopKeysSection(recorder: model.recorder, palette: palette)
            case .agents:
                SetupAgentsStep(model: model.setup).task { await model.setup.refresh() }
            case .notifications:
                VStack(alignment: .leading, spacing: 16) {
                    SetupNotificationsStep(model: model.setup)
                    SetupPermissionPanel(model: model.setup)
                }.task { await model.setup.refresh() }
            case .advanced: advanced
            default: registryGroup(model.section)
            }
        }
    }

    private var general: some View {
        DesktopSettingsGroup(palette: palette) {
            DesktopSettingsRow(title: "Версия", palette: palette) { Text(model.version).textSelection(.enabled) }
            DesktopSettingsRow(title: "Файл конфигурации", palette: palette) {
                Text(model.configFile.configPath ?? "не найден").lineLimit(1).truncationMode(.middle)
            }
            DesktopSettingsRow(title: "Пример команды", palette: palette) {
                Text("mitts --help").font(.system(size: DesktopMetrics.bodyFontSize, design: .monospaced))
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            DesktopSettingsGroup(palette: palette) {
                DesktopSettingsRow(title: "Файл конфигурации", palette: palette) {
                    HStack {
                        Button("Show in Finder") { model.revealConfig() }
                        Button("Перечитать") { (NSApp.delegate as? AppDelegate)?.tako.reloadConfig() }
                    }
                }
            }
            registryGroup(.advanced)
        }
    }

    @ViewBuilder
    private func registryGroup(_ section: DesktopSettingsSection) -> some View {
        let items = Self.items(for: section)
        if items.isEmpty {
            Text("Нет параметров").foregroundStyle(Color(palette.muted))
        } else {
            DesktopSettingsGroup(palette: palette) {
                ForEach(items, id: \.id) { item in
                    DesktopRegistryRow(item: item, preferences: model.preferences, palette: palette)
                }
            }
        }
    }

    static func items(for section: DesktopSettingsSection) -> [TerminalSettingItem] {
        let handledElsewhere: Set<String> = ["theme", "font-size"]
        return TerminalSettingRegistry.allSettings.filter {
            !handledElsewhere.contains($0.id) && DesktopSettingsSection.section(forCategory: $0.category) == section
        }
    }
}

struct DesktopSettingsGroup<Content: View>: View {
    let palette: DesktopPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.panelRadius).fill(Color(palette.panel)))
            .overlay(RoundedRectangle(cornerRadius: DesktopMetrics.panelRadius).stroke(Color(palette.border)))
    }
}

struct DesktopSettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    let palette: DesktopPalette
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Color(palette.muted)) }
            }
            Spacer(minLength: 12)
            control.frame(minHeight: DesktopMetrics.controlHeight)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }
}

/// One registry setting with its live value, source and reset.
struct DesktopRegistryRow: View {
    let item: TerminalSettingItem
    @ObservedObject var preferences: DesktopPreferenceStore
    let palette: DesktopPalette

    var body: some View {
        let local = preferences.isOverridden(item.id)
        DesktopSettingsRow(title: item.title, detail: local ? "Своё значение · \(item.id)" : "По умолчанию · \(item.id)",
                           palette: palette) {
            HStack(spacing: 6) {
                control
                if local {
                    Button { preferences.reset(item.id) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help("Сбросить к значению по умолчанию")
                }
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch item.type {
        case .boolean:
            Toggle("", isOn: Binding(get: { preferences.bool(item.id) },
                                     set: { preferences.set(item.id, $0 ? "true" : "false") }))
                .toggleStyle(.switch).labelsHidden()
        case .options(let options, _):
            Picker("", selection: Binding(get: { preferences.value(item.id) }, set: { preferences.set(item.id, $0) })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 160)
        case .number(_, let min, let max, let step):
            let value = Int(Double(preferences.value(item.id)) ?? 0)
            Stepper("\(value)", value: Binding(get: { value }, set: { preferences.set(item.id, String($0)) }),
                    in: min...max, step: step)
        case .color:
            DesktopColorField(value: preferences.value(item.id)) { preferences.set(item.id, $0) }
        }
    }
}

struct DesktopColorField: View {
    let value: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: NSColor(hex: value) ?? .clear)).frame(width: 18, height: 18)
            TextField("#rrggbb", text: $text).frame(width: 90).onSubmit { commit(text) }
        }.onAppear { text = value }.onChange(of: value) { text = $0 }
    }
}

struct DesktopSettingsErrorLine: View {
    @ObservedObject var preferences: DesktopPreferenceStore
    @ObservedObject var scope: DesktopScopeEditor
    @ObservedObject var themes: DesktopThemeLibrary
    @ObservedObject var recorder: DesktopShortcutRecorder
    let palette: DesktopPalette

    var body: some View {
        if let error = scope.lastError ?? preferences.lastError ?? themes.lastError ?? recorder.lastError {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(palette.accent))
            Text(error).lineLimit(2).foregroundStyle(Color(palette.secondary))
        }
    }
}
