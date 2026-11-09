/*
 * tako — Keyboard shortcut list with recorder, conflict review and resets
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

struct DesktopKeysSection: View {
    @ObservedObject var recorder: DesktopShortcutRecorder
    @ObservedObject private var file: KeybindConfigFile
    let palette: DesktopPalette
    @State private var query = ""

    init(recorder: DesktopShortcutRecorder, palette: DesktopPalette) {
        _recorder = ObservedObject(wrappedValue: recorder)
        _file = ObservedObject(wrappedValue: recorder.configFile)
        self.palette = palette
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Поиск действия", text: $query).textFieldStyle(.roundedBorder)
                Button("Восстановить все по умолчанию") { recorder.resetAll() }
                    .disabled(file.customOverrides.isEmpty)
            }
            if case .conflict(_, let trigger, let holder) = recorder.state {
                conflictBanner(trigger: trigger, holder: holder)
            }
            ForEach(KeybindCategory.allCases) { category in
                let actions = filtered(category)
                if !actions.isEmpty {
                    Text(category.rawValue).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(palette.muted))
                    DesktopSettingsGroup(palette: palette) {
                        ForEach(actions) { action in row(action) }
                    }
                }
            }
        }
    }

    private func filtered(_ category: KeybindCategory) -> [KeybindActionItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return KeybindRegistry.allActions.filter {
            $0.category == category && (q.isEmpty || $0.title.lowercased().contains(q) || $0.id.contains(q))
        }
    }

    private func conflictBanner(trigger: String, holder: DesktopShortcutRecorder.KeybindHolder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(palette.accent))
            Text("\(KeybindRegistry.format(trigger: trigger)) уже назначено: \(holder.title)")
            Spacer()
            Button("Reassign") { recorder.confirmReassign() }
            Button("Cancel") { recorder.cancel() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius).fill(Color(palette.raised)))
    }

    private func row(_ action: KeybindActionItem) -> some View {
        let recording = recorder.recordingAction == action.id
        return HStack(spacing: 8) {
            Text(action.title)
            Spacer()
            Button {
                recording ? recorder.cancel() : recorder.begin(action.id)
            } label: {
                Text(recording ? "Нажмите сочетание… (Esc — отмена)" : (recorder.display(for: action.id) ?? "Не назначено"))
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 90, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(recording ? palette.accent : palette.border)))
            }.buttonStyle(.plain)
            if recorder.isCustom(action.id) {
                Button { recorder.reset(action.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Вернуть сочетание по умолчанию")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: DesktopMetrics.navigationRowHeight)
    }
}
