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
    /// The Keys page's own filter (by title, id or shortcut) and the row
    /// whose Record / Reset buttons are shown.
    @Published var keysQuery = ""
    @Published var selectedShortcut: String?
    /// A search hit to scroll to and mark on its page.
    @Published var highlight: String?
    @Published var draft: DesktopThemeDraft?
    @Published private(set) var draftError: String?

    let configFile: KeybindConfigFile
    let preferences: DesktopPreferenceStore
    let recorder: DesktopShortcutRecorder
    let themes: DesktopThemeLibrary
    let scope: DesktopScopeEditor
    let fonts: [String]
    var onClose: () -> Void = {}
    /// Global › workspace › session › terminal of the terminal the settings
    /// were opened over; the chips switch the edited level among them.
    var levels: [DesktopScopeLevel] = [.global]
    var onSelectLevel: (DesktopScopeLevel) -> Void = { _ in }

    /// The level being edited, matched by scope.
    var currentLevel: DesktopScopeLevel? {
        levels.first { $0.scope == scope.context?.scope }
    }
    /// The window the settings sit in; the live preview targets its panes.
    weak var hostWindow: NSWindow?
    /// Live panes showing the draft; nil when no draft is open.
    private(set) var preview: ThemePresetPreview?
    /// Called after a saved theme is selected, so open terminals re-resolve.
    var reloadApp: () -> Void = DesktopThemeLibrary.reloadLiveApp
    private var setupModel: SetupModel?

    init(configPath: String?, context: ScopedAppearanceContext? = nil,
         section: DesktopSettingsSection = .general, scopes: ScopedAppearanceStore = .shared,
         themeStore: ThemePresetStore? = nil, fonts: [String]? = nil) {
        let file = KeybindConfigFile(configPath: configPath)
        file.reload()
        configFile = file
        preferences = DesktopPreferenceStore(configFile: file)
        recorder = DesktopShortcutRecorder(configFile: file)
        let directory = URL(fileURLWithPath: file.configPath ?? NSTemporaryDirectory())
            .deletingLastPathComponent().appendingPathComponent("themes", isDirectory: true)
        let store = themeStore ?? ThemePresetStore(directory: directory, searchPaths: file.appearanceThemePaths)
        scope = DesktopScopeEditor(context: context, preferences: preferences, themePaths: store.searchPaths)
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
        switch result.kind {
        case .action(let id): showShortcut(id); return
        case .setting(let key): highlight = key
        case .font(let family): highlight = family
        case .section: highlight = nil
        }
        section = result.section
        query = ""
    }

    /// Opens Keys on one action: filtered to it and selected.
    func showShortcut(_ action: String) {
        query = ""
        section = .keys
        keysQuery = KeybindRegistry.allActions.first { $0.id == action }?.title ?? action
        selectedShortcut = action
    }

    /// The config file as it is on disk now.
    var configText: String {
        guard let path = configFile.configPath else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    // MARK: Theme draft

    /// Opens a draft and fixes the preview targets: the live panes of the
    /// host window that this level reaches right now.
    func editTheme(_ name: String, asCopy: Bool = false) {
        endPreview()
        draft = themes.beginDraft(name, asCopy: asCopy)
        draftError = draft == nil ? themes.lastError : nil
        guard let draft else { return }
        preview = ThemePresetPreview(owner: self, scope: scope.context?.scope, window: hostWindow)
        applyPreview(draft)
    }

    func updateDraft(_ change: (inout DesktopThemeDraft) -> Void) {
        guard var current = draft else { return }
        change(&current)
        draft = current
        applyPreview(current)
    }

    /// Restores the previewed panes first (so a failed save leaves nothing
    /// half-applied), writes the theme, selects it for this level and asks
    /// the app to re-resolve every open terminal.
    @discardableResult
    func saveDraft() -> Bool {
        guard let current = draft else { return false }
        guard current.canSave else {
            draftError = current.nameError ?? current.configError
            return false
        }
        endPreview()
        guard let saved = themes.save(current) else {
            draftError = themes.lastError
            preview = ThemePresetPreview(owner: self, scope: scope.context?.scope, window: hostWindow)
            applyPreview(current)
            return false
        }
        draft = nil
        draftError = nil
        let selected = scope.selectPreset(saved.name)
        reloadApp()
        return selected
    }

    /// Cancel and close: the panes get their earlier look back, or, when the
    /// config or scoped appearance changed meanwhile, re-resolve from it.
    func cancelDraft() {
        endPreview()
        draft = nil
        draftError = nil
    }

    private func applyPreview(_ draft: DesktopThemeDraft) {
        // Terminal light/dark pairs follow the system, not Tako's chrome scheme.
        preview?.apply(draft.preview(dark: TakoSystemAppearance.isDark))
    }

    private func endPreview() {
        preview?.restore()
        preview = nil
    }

    func revealConfig() {
        guard let path = configFile.configPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
