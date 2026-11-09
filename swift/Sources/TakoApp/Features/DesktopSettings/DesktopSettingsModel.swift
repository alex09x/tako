/*
 * tako — State shared by every native settings section
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor
final class DesktopSettingsModel: ObservableObject {
    @Published var section: DesktopSettingsSection
    @Published var query = ""
    @Published var draft: DesktopThemeDraft?
    @Published private(set) var draftError: String?

    let configFile: KeybindConfigFile
    let preferences: DesktopPreferenceStore
    let recorder: DesktopShortcutRecorder
    let themes: DesktopThemeLibrary
    let scope: DesktopScopeEditor
    let fonts: [String]
    var onClose: () -> Void = {}
    private var setupModel: SetupModel?

    init(configPath: String?, context: ScopedAppearanceContext? = nil,
         section: DesktopSettingsSection = .general, scopes: ScopedAppearanceStore = .shared,
         themeStore: ThemePresetStore? = nil, fonts: [String]? = nil) {
        let file = KeybindConfigFile(configPath: configPath)
        file.reload()
        configFile = file
        preferences = DesktopPreferenceStore(configFile: file)
        recorder = DesktopShortcutRecorder(configFile: file)
        scope = DesktopScopeEditor(context: context, preferences: preferences)
        let directory = URL(fileURLWithPath: file.configPath ?? NSTemporaryDirectory())
            .deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
        let store = themeStore ?? ThemePresetStore(directory: directory, searchPaths: file.appearanceThemePaths)
        themes = DesktopThemeLibrary(store: store, scopes: context?.store ?? scopes, configFile: file)
        self.fonts = fonts ?? TerminalAppearanceCatalog.fontFamilies()
        self.section = context != nil && section == .general ? .terminalAppearance : section
    }

    /// Lazily created; its refresh only reads status and never prompts or installs.
    var setup: SetupModel {
        if let setupModel { return setupModel }
        let model = SetupModel(configPath: configFile.configPath)
        setupModel = model
        return model
    }

    var searchResults: [DesktopSettingsSearchResult] {
        DesktopSettingsSearch.results(query, fonts: fonts)
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        default: return "Unknown"
        }
    }

    var fallbackFontFamily: String {
        Tako.LivingTokens.monoFont(size: DesktopMetrics.bodyFontSize).familyName ?? "Menlo"
    }

    func fontResolution() -> DesktopFontResolution {
        .resolve(scope.effectiveValue("font-family"), inventory: fonts, fallback: fallbackFontFamily)
    }

    func open(_ result: DesktopSettingsSearchResult) {
        section = result.section
        query = ""
    }

    // MARK: Theme draft

    func editTheme(_ name: String) {
        draft = themes.beginDraft(name)
        draftError = draft == nil ? themes.lastError : nil
    }

    func updateDraft(_ change: (inout DesktopThemeDraft) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
    }

    @discardableResult
    func saveDraft() -> Bool {
        guard let current = draft else { return false }
        guard let saved = themes.save(current) else {
            draftError = themes.lastError
            return false
        }
        draft = nil
        draftError = nil
        return scope.selectPreset(saved.name)
    }

    func cancelDraft() {
        draft = nil
        draftError = nil
    }

    func revealConfig() {
        guard let path = configFile.configPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
