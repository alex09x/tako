/*
 * tako — Installed/bundled theme catalog with safe custom theme management
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

enum DesktopThemeError: LocalizedError, Equatable {
    /// Deleting or renaming would orphan these references; nothing was changed.
    case referenced(String, [String])

    var errorDescription: String? {
        switch self {
        case .referenced(let name, let refs):
            "Theme “\(name)” is used by \(refs.joined(separator: ", ")). Choose another theme for them before deleting it."
        }
    }
}

@MainActor
final class DesktopThemeLibrary: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let name: String
        let isUser: Bool
        var id: String { name }
    }

    let store: ThemePresetStore
    let scopes: ScopedAppearanceStore
    let configFile: KeybindConfigFile
    @Published private(set) var entries: [Entry] = []
    @Published var lastError: String?

    init(store: ThemePresetStore, scopes: ScopedAppearanceStore, configFile: KeybindConfigFile) {
        self.store = store
        self.scopes = scopes
        self.configFile = configFile
        reload()
    }

    func reload() {
        let user = store.directory.path
        entries = TerminalAppearanceCatalog.themeNames(paths: [user] + store.searchPaths).map { name in
            Entry(name: name, isUser: FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name).path))
        }
    }

    /// Every place that would lose its theme if `name` disappeared.
    func references(to name: String) -> [String] {
        var refs: [String] = []
        if let item = DesktopPreferenceStore.item("theme"), configFile.getSettingValue(for: item) == name {
            refs.append("Global settings")
        }
        let doc = scopes.document
        for (id, fields) in doc.workspaces.sorted(by: { $0.key < $1.key }) where fields["theme"] == name {
            refs.append(WorkspaceStore.shared.workspace(for: UUID(uuidString: id) ?? UUID()).map { "workspace “\($0.name)”" } ?? "workspace \(id.prefix(8))")
        }
        for (id, fields) in doc.sessions.sorted(by: { $0.key < $1.key }) where fields["theme"] == name {
            refs.append("session \(id.prefix(8))")
        }
        for (id, fields) in doc.panes.sorted(by: { $0.key < $1.key }) where fields["theme"] == name {
            refs.append("terminal \(id.prefix(8))")
        }
        return refs
    }

    @discardableResult
    func duplicate(_ name: String, as newName: String) -> ThemePreset? {
        perform {
            let source = try store.load(named: name)
            return try store.save(name: newName, config: source.config)
        }
    }

    /// Rename keeps references valid: a referenced theme is never moved away.
    @discardableResult
    func rename(_ name: String, to newName: String) -> ThemePreset? {
        perform {
            let refs = references(to: name)
            guard refs.isEmpty else { throw DesktopThemeError.referenced(name, refs) }
            let original = try store.load(named: name)
            let copy = try store.copyForRename(original, to: newName)
            _ = try store.remove(original)
            return copy
        }
    }

    @discardableResult
    func delete(_ name: String) -> Bool {
        perform { () -> Bool in
            let refs = references(to: name)
            guard refs.isEmpty else { throw DesktopThemeError.referenced(name, refs) }
            _ = try store.remove(try store.load(named: name))
            return true
        } ?? false
    }

    func beginDraft(_ name: String) -> DesktopThemeDraft? {
        perform { DesktopThemeDraft(original: try store.load(named: name)) }
    }

    /// Saves a user theme in place (stale-checked) or a builtin as a new copy.
    @discardableResult
    func save(_ draft: DesktopThemeDraft) -> ThemePreset? {
        perform {
            if draft.original.isUser && draft.name == draft.original.name {
                return try store.save(name: draft.name, config: draft.text, replacing: draft.original)
            }
            return try store.save(name: draft.name, config: draft.text)
        }
    }

    private func perform<T>(_ body: () throws -> T) -> T? {
        do {
            let value = try body()
            lastError = nil
            reload()
            return value
        } catch {
            lastError = error.localizedDescription
            reload()
            return nil
        }
    }
}
