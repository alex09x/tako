/*
 * tako — Desktop settings theme catalog: duplicate, draft, rename, delete
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

enum DesktopThemeError: LocalizedError, Equatable {
    /// Deleting would orphan these references; nothing was changed.
    case referenced(String, [String])
    case noConfiguration

    var errorDescription: String? {
        switch self {
        case .referenced(let name, let refs):
            "Theme “\(name)” is used by \(refs.joined(separator: ", ")). Choose another theme for them before deleting it."
        case .noConfiguration:
            "No configuration file is available to save themes."
        }
    }
}

/// The settings view of the theme catalog. Rename and delete go through
/// ThemeControlService, the same transactional path `takoctl theme` uses:
/// rename copies first and moves every reference, delete refuses while the
/// theme is assigned anywhere.
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
    private let reloadApp: () -> Void
    @Published private(set) var entries: [Entry] = []
    @Published var lastError: String?

    init(store: ThemePresetStore, scopes: ScopedAppearanceStore, configFile: KeybindConfigFile,
         reloadApp: @escaping () -> Void = DesktopThemeLibrary.reloadLiveApp) {
        self.store = store
        self.scopes = scopes
        self.configFile = configFile
        self.reloadApp = reloadApp
        reload()
    }

    static func reloadLiveApp() { (NSApp.delegate as? AppDelegate)?.tako.reloadConfig() }

    func reload() {
        let user = store.directory.path
        entries = TerminalAppearanceCatalog.themeNames(paths: [user] + store.searchPaths).map { name in
            Entry(name: name, isUser: FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(name).path))
        }
    }

    /// The control service keeps its user themes next to the config file,
    /// which is where `store` lives too (DesktopSettingsModel derives both).
    private func service() throws -> ThemeControlService {
        guard let path = configFile.configPath else { throw DesktopThemeError.noConfiguration }
        return ThemeControlService(configURL: URL(fileURLWithPath: path), appearances: scopes,
                                   themePaths: store.searchPaths, reload: reloadApp)
    }

    /// Every place that would lose its theme if `name` disappeared, named for people.
    func references(to name: String) -> [String] {
        ((try? service().references(to: name)) ?? []).map(Self.label)
    }

    static func label(_ reference: String) -> String {
        guard let colon = reference.firstIndex(of: ":") else {
            return reference == "global" ? "Global settings" : reference
        }
        let kind = reference[..<colon], id = String(reference[reference.index(after: colon)...])
        switch kind {
        case "workspace":
            return UUID(uuidString: id).flatMap { WorkspaceStore.shared.workspace(for: $0) }
                .map { "workspace “\($0.name)”" } ?? "workspace \(id.prefix(8))"
        case "session": return "session \(id.prefix(8))"
        case "pane": return "terminal \(id.prefix(8))"
        default: return reference
        }
    }

    @discardableResult
    func duplicate(_ name: String, as newName: String) -> ThemePreset? {
        perform {
            let source = try store.load(named: name)
            return try store.save(name: newName, config: source.config)
        }
    }

    /// Copies first, moves the global, workspace, session and pane references,
    /// then removes the old file; a failure keeps both files and rolls back.
    @discardableResult
    func rename(_ name: String, to newName: String) -> ThemePreset? {
        perform {
            _ = try service().renamePreset(["name": .string(name), "new_name": .string(newName)])
            return try store.load(named: newName)
        }
    }

    /// Refused while assigned anywhere; the error lists where, by name.
    @discardableResult
    func delete(_ name: String) -> Bool {
        perform { () -> Bool in
            let refs = references(to: name)
            guard refs.isEmpty else { throw DesktopThemeError.referenced(name, refs) }
            _ = try service().deletePreset(["name": .string(name)])
            return true
        } ?? false
    }

    /// A built-in theme, or a user theme with `asCopy`, opens as «X Copy»
    /// («X Copy 2» … when taken); a user theme otherwise opens in place.
    func beginDraft(_ name: String, asCopy: Bool = false) -> DesktopThemeDraft? {
        perform {
            let original = try store.load(named: name)
            guard asCopy || !original.isUser else { return DesktopThemeDraft(original: original) }
            return DesktopThemeDraft(original: original, name: uniqueName(original.name + " Copy"))
        }
    }

    func uniqueName(_ base: String) -> String {
        let taken = Set(entries.map { $0.name.lowercased() })
        var candidate = base, index = 2
        while taken.contains(candidate.lowercased()) { candidate = "\(base) \(index)"; index += 1 }
        return candidate
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
        } catch let error as ControlError {
            lastError = error.message
            reload()
            return nil
        } catch {
            lastError = error.localizedDescription
            reload()
            return nil
        }
    }
}
