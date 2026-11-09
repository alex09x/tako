/*
 * tako — Desktop settings Keys page: filter, groups, recorder, conflict
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// The reference's Keys page (pfPageKeys). Clicking a row selects it and
/// starts recording; the selected row carries the Record and Reset controls.
/// Accessibility: `DesktopShortcut-<action>` rows, `DesktopShortcutRecord`,
/// `DesktopShortcutReset`, `DesktopShortcutConflict` with
/// `DesktopShortcutConflictCancel` / `DesktopShortcutConflictConfirm`.
struct DesktopKeysSection: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject var recorder: DesktopShortcutRecorder
    @ObservedObject private var file: KeybindConfigFile
    let palette: DesktopPalette
    @State private var changedOnly = false

    init(model: DesktopSettingsModel, recorder: DesktopShortcutRecorder, palette: DesktopPalette) {
        _model = ObservedObject(wrappedValue: model)
        _recorder = ObservedObject(wrappedValue: recorder)
        _file = ObservedObject(wrappedValue: recorder.configFile)
        self.palette = palette
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Action or shortcut: “split down”, “⇧⌘D”, “cmd+d”", text: $model.keysQuery)
                        .desktopField(palette)
                        .accessibilityIdentifier("DesktopShortcutFilter")
                    DesktopSegment(options: [("all", "All"), ("changed", changedLabel)], selection: changedOnly ? "changed" : "all",
                                   identifier: "DesktopShortcutShow", palette: palette) { changedOnly = $0 == "changed" }
                }
                DesktopHint(text: "Select an action and press a shortcut with ⌘, ⌃, ⌥ or a function key. Esc to cancel, ⌫ to restore the default. These shortcuts work inside Tako.",
                            palette: palette)
                    .padding(.bottom, 8)
                let groups = KeybindCategory.allCases.map { ($0, actions(in: $0)) }.filter { !$0.1.isEmpty }
                if groups.isEmpty {
                    DesktopHint(text: changedOnly ? "No changes — all shortcuts use their defaults." : "No results.", palette: palette)
                }
                ForEach(groups, id: \.0) { category, actions in
                    group(category, actions)
                }
            }
            .onChange(of: model.selectedShortcut) { _, id in
                if let id { withAnimation(nil) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private var changedLabel: String {
        let count = file.customOverrides.count
        return count > 0 ? "Modified · \(count)" : "Modified"
    }

    private func actions(in category: KeybindCategory) -> [KeybindActionItem] {
        let q = model.keysQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return KeybindRegistry.allActions.filter { action in
            guard action.category == category, !changedOnly || recorder.isCustom(action.id) else { return false }
            guard !q.isEmpty else { return true }
            let current = file.customOverrides[KeybindConfigFile.canonicalActionName(action.id)]
            return DesktopKeysCopy.searchTexts(action.id, current: current).contains { $0.lowercased().contains(q) }
        }
    }

    private func group(_ category: KeybindCategory, _ actions: [KeybindActionItem]) -> some View {
        let heading = DesktopKeysCopy.group(category)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading.title).font(.system(size: DesktopSettingsStyle.captionSize, weight: .semibold))
                    .foregroundStyle(Color(palette.text))
                if !heading.note.isEmpty {
                    Text(heading.note).font(.system(size: 10)).foregroundStyle(Color(palette.muted))
                }
            }
            ForEach(actions) { action in
                row(action).id(action.id)
                if case .conflict(let target, let trigger, let holder) = recorder.state, target == action.id {
                    conflict(trigger: trigger, holder: holder)
                }
            }
        }
        .padding(.top, 8)
    }

    private func row(_ action: KeybindActionItem) -> some View {
        let selected = model.selectedShortcut == action.id
        let recording: Bool = { if case .recording(let a) = recorder.state { return a == action.id } else { return false } }()
        return HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DesktopKeysCopy.title(action.id)).font(.system(size: DesktopMetrics.bodyFontSize, weight: .medium))
                    .foregroundStyle(Color(palette.text)).lineLimit(1)
                Text(action.id).font(.system(size: DesktopSettingsStyle.keySize, design: .monospaced))
                    .foregroundStyle(Color(palette.faint)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { start(action.id) } label: {
                Group {
                    if recording {
                        Text("Press a shortcut…").font(.system(size: DesktopSettingsStyle.captionSize))
                            .foregroundStyle(Color(palette.accentBright))
                    } else {
                        DesktopShortcutCaps(text: recorder.display(for: action.id), palette: palette)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(selected ? "DesktopShortcutRecord" : "DesktopShortcutRecord-\(action.id)")
            .accessibilityLabel(recording ? "Recording Shortcut" : "Record Shortcut")
            Group {
                if recorder.isCustom(action.id) {
                    Button { recorder.reset(action.id) } label: { Text("↺") }
                        .buttonStyle(.plain).foregroundStyle(Color(palette.muted)).help("Restore Default")
                        .accessibilityIdentifier(selected ? "DesktopShortcutReset" : "DesktopShortcutReset-\(action.id)")
                }
            }.frame(width: 28)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowFill(selected: selected, recording: recording)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? Color(palette.accentBright) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedShortcut = action.id }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DesktopShortcut-\(action.id)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func rowFill(selected: Bool, recording: Bool) -> Color {
        recording || selected ? Color(palette.raised) : .clear
    }

    private func start(_ action: String) {
        model.selectedShortcut = action
        recorder.begin(action)
    }

    private func conflict(trigger: String, holder: DesktopShortcutRecorder.KeybindHolder) -> some View {
        let keys = KeybindRegistry.format(trigger: trigger)
        return HStack(spacing: 8) {
            Text("\(keys) is assigned to “\(holder.title)”. Reassigning it removes that action’s shortcut.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") { recorder.cancel(message: "Reassignment canceled") }
                .buttonStyle(DesktopButtonStyle(palette: palette))
                .accessibilityIdentifier("DesktopShortcutConflictCancel")
            Button("Reassign") { recorder.confirmReassign() }
                .buttonStyle(DesktopButtonStyle(primary: true, palette: palette))
                .accessibilityIdentifier("DesktopShortcutConflictConfirm")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Self.warning.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.warning.opacity(0.4)))
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DesktopShortcutConflict")
    }

    /// `rgba(240,198,116,…)` in the reference: a caution tint, not a status colour.
    private static let warning = Color(red: 240 / 255, green: 198 / 255, blue: 116 / 255)
}
