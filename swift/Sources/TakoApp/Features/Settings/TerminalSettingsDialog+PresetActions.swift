/*
 * tako — Create, preview and save named themes
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension TerminalSettingsDialog {
    func beginPresetEditor(createNew: Bool) {
        guard presetEditor == nil, activeTab == .themes, let window, let content = superview, let path = configFile.configPath else { return }
        cancelEditingColor()
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
        let store = ThemePresetStore(directory: directory, searchPaths: configFile.appearanceThemePaths)
        let base = scopedAppearance?.effectiveTheme
            ?? (window.windowController as? TerminalController)?.tako.config.theme ?? .takoDefault
        do {
            let selected = selectedSettingIndex < filteredSettingItems.count ? filteredSettingItems[selectedSettingIndex] : nil
            let selectedName = selected?.category == TerminalAppearanceCatalog.themeCategory && selected?.title != inheritanceTitle
                ? selected?.title : nil
            let name = selectedName ?? TerminalSettingRegistry.setting(for: "theme").flatMap { storedSettingValue(for: $0) } ?? "TakoCore"
            let inherited = scopedAppearance != nil && selected?.title == inheritanceTitle
            let source = createNew || inherited ? nil : try store.load(named: name.lowercased() == "tako" ? "TakoCore" : name)
            var copyName = createNew ? "New Theme" : inherited ? "Custom Theme" : "\(source?.name ?? name) Copy"
            let names = Set(TerminalAppearanceCatalog.themeNames(paths: configFile.appearanceThemePaths).map { $0.lowercased() })
            let initialName = copyName
            var suffix = 2
            while names.contains(copyName.lowercased()) { copyName = "\(initialName) \(suffix)"; suffix += 1 }
            let editor = ThemePresetEditor(store: store, original: source, base: base, copyName: copyName)
            editor.parent = self
            editor.preview = ThemePresetPreview(owner: self)
            let dialog = TerminalSettingsDialog(style: .from(base), configFile: configFile, initialTab: .themes, editor: editor)
            dialog.frame = content.bounds
            dialog.autoresizingMask = [.width, .height]
            dialog.previousResponder = self
            isHidden = true
            content.addSubview(dialog, positioned: .above, relativeTo: nil)
            dialog.previewEditedTheme()
            window.makeFirstResponder(dialog.presetNameField ?? dialog)
            dialog.presetNameField?.currentEditor()?.selectAll(nil)
            dialog.needsLayout = true
        } catch {
            statusMessage = error.localizedDescription
            setAccessibilityValue("theme_open_error: \(error.localizedDescription)")
            needsDisplay = true
        }
    }

    func previewPreset() {
        guard let editor = presetEditor else { return }
        if colorEditField != nil {
            saveEditedColor()
            guard colorEditField == nil else { return }
        }
        do {
            let theme = try editor.validatedTheme()
            let count = editor.preview?.apply(theme) ?? 0
            guard count > 0 else {
                statusMessage = "No live pane is available for preview."
                setAccessibilityValue("theme_preview_error: no_live_panes")
                needsDisplay = true
                return
            }
            statusMessage = "Live preview · Save theme · Cancel restores"
            setAccessibilityValue("theme_preview_success: \(count) panes")
        } catch {
            statusMessage = error.localizedDescription
            setAccessibilityValue("theme_preview_error: \(error.localizedDescription)")
        }
        needsDisplay = true
    }

    func savePreset() {
        guard let editor = presetEditor else { return }
        if colorEditField != nil {
            saveEditedColor()
            guard colorEditField == nil else { return }
        }
        editor.preview?.restore()
        do {
            let saved = try editor.save()
            if let parent = editor.parent {
                parent.themePreviews.removeAll()
                parent.searchField?.stringValue = ""
                parent.filterItems("")
                let themeItem = TerminalSettingItem(id: "theme", title: saved.name, category: TerminalAppearanceCatalog.themeCategory,
                    type: .options(options: [saved.name], defaultValue: "TakoCore"), description: "Saved full theme preset")
                parent.applyAppearanceChoice(themeItem)
                if let index = parent.filteredSettingItems.firstIndex(where: { $0.id == "theme" && $0.title == saved.name }) {
                    parent.selectedSettingIndex = index
                    parent.scrollSettingOffset = max(0, index - parent.visibleRows + 1)
                }
                if parent.scopedAppearance != nil {
                    (parent.window?.windowController as? TerminalController)?.tako.reloadConfig()
                }
            }
            setAccessibilityValue("theme_save_success: \(saved.name)")
            withdraw()
        } catch {
            statusMessage = error.localizedDescription
            setAccessibilityValue("theme_save_error: \(error.localizedDescription)")
            needsDisplay = true
        }
    }

    func finishPresetEditor() {
        guard let editor = presetEditor else { return }
        editor.preview?.restore()
        if let parent = editor.parent, !parent.isWithdrawing {
            parent.isHidden = false
            parent.needsDisplay = true
        }
    }
}
