/*
 * tako — Effective value/source vs local override for every appearance scope
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

/// One editing target. Global writes go to the config file; workspace,
/// session and pane writes go to ScopedAppearanceStore through the
/// dependency's real inheritance chain (ScopedAppearanceContext).
@MainActor
final class DesktopScopeEditor: ObservableObject {
    enum Source: Equatable {
        case local
        case inherited(String)
        case defaultValue
    }

    let context: ScopedAppearanceContext?
    let preferences: DesktopPreferenceStore
    @Published private(set) var lastError: String?
    @Published private(set) var revision = 0

    /// Where preset names resolve; injectable so tests use a sandbox.
    let themePaths: [String]

    init(context: ScopedAppearanceContext?, preferences: DesktopPreferenceStore, themePaths: [String]? = nil) {
        self.context = context
        self.preferences = preferences
        self.themePaths = themePaths ?? preferences.configFile.appearanceThemePaths
    }

    var title: String { context?.title ?? "Global Settings" }
    var isGlobal: Bool { context == nil }

    var parentTitle: String {
        switch context?.scope {
        case .workspace: "global settings"
        case .session: "workspace"
        case .pane: "session"
        case nil: "default values"
        }
    }

    func localValue(_ key: String) -> String? {
        if let context { return context.value(for: key) }
        return preferences.localValue(key)
    }

    func source(_ key: String) -> Source {
        if localValue(key) != nil { return .local }
        return isGlobal ? .defaultValue : .inherited(parentTitle)
    }

    func sourceLabel(_ key: String) -> String {
        switch source(key) {
        case .local: "Custom value"
        case .inherited(let parent): "Inherited from \(parent)"
        case .defaultValue: "Default"
        }
    }

    /// What the terminal actually uses at this level, theme resolved.
    func effectiveValue(_ key: String) -> String? {
        if let context { return context.effectiveValue(for: key) ?? context.value(for: key) }
        return preferences.effectiveValue(key)
    }

    var effectiveTheme: TerminalTheme? { context?.effectiveTheme }

    /// What terminals at this level render: the scoped chain, or the config
    /// file parsed with its theme for the global level.
    var renderedTheme: TerminalTheme {
        if let context { return context.effectiveTheme }
        let file = preferences.configFile
        return TerminalTheme.parse(config: file.rawConfigLines.joined(separator: "\n"), configPath: file.configPath,
                                   darkAppearance: TakoSystemAppearance.isDark)
    }

    /// Whether this level stores anything of its own (theme or fields).
    var hasOwnOverrides: Bool {
        if let context { return context.store.document.overrides(for: context.scope)?.isEmpty == false }
        return ScopedAppearanceContext.keys.contains { preferences.localValue($0) != nil }
    }

    /// «Global › …» down to this level, for the chips over the page.
    var chain: [String] { context.map { ["Global", $0.title] } ?? ["Global"] }

    @discardableResult
    func set(_ key: String, _ value: String) -> Bool {
        if let context {
            return finish(context.setValue(value, for: key), context.writeError)
        }
        return finish(preferences.set(key, value), preferences.lastError)
    }

    /// Removes only this level's override; the parent value shows through.
    @discardableResult
    func inherit(_ key: String) -> Bool {
        if let context { return finish(context.setValue(nil, for: key), context.writeError) }
        return finish(preferences.reset(key), preferences.lastError)
    }

    /// Same rule as ThemeControlService.applyPreset: a full preset replaces
    /// this level's own overrides only; a colours-only one is just selected.
    @discardableResult
    func selectPreset(_ name: String) -> Bool {
        let full = TerminalTheme.presetContainsTypography(named: name, searchPaths: themePaths)
        guard let context else { return finish(preferences.selectPreset(name, full: full), preferences.lastError) }
        guard context.isAvailable() else { return finish(false, "This workspace or terminal is no longer available.") }
        do {
            if full { try context.store.applyPreset(name, scope: context.scope) }
            else { try context.store.setValue(name, for: "theme", scope: context.scope) }
            return finish(true, nil)
        } catch {
            return finish(false, error.localizedDescription)
        }
    }

    /// Drops every override this level owns; parents and siblings are untouched.
    @discardableResult
    func resetAll() -> Bool {
        guard let context else {
            let keys = ScopedAppearanceContext.keys.sorted().filter { DesktopPreferenceStore.item($0) != nil }
            let ok = keys.allSatisfy { preferences.reset($0) }
            return finish(ok, preferences.lastError)
        }
        do {
            try context.store.reset(context.scope)
            return finish(true, nil)
        } catch {
            return finish(false, error.localizedDescription)
        }
    }

    private func finish(_ ok: Bool, _ error: String?) -> Bool {
        lastError = ok ? nil : (error ?? "Could not save this change")
        revision += 1
        return ok
    }
}

/// Requested vs actually rendered font family.
struct DesktopFontResolution: Equatable {
    let requested: String?
    let rendered: String
    var isFallback: Bool { requested != nil && requested != rendered }

    static func resolve(_ requested: String?, inventory: [String], fallback: String) -> DesktopFontResolution {
        guard let requested, requested != TerminalAppearanceCatalog.defaultFont else {
            return .init(requested: nil, rendered: fallback)
        }
        return .init(requested: requested, rendered: inventory.contains(requested) ? requested : fallback)
    }
}
