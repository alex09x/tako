/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import TakoCoreUI

/// Main actor store for versioned scoped appearance overrides (workspace, session and pane).
///
/// Ensures atomic disk writes before updating in-memory state or publishing notifications.
/// Protects corrupt or unknown-version persistence files against being overwritten.
@MainActor
public final class ScopedAppearanceStore {
    public static let shared = ScopedAppearanceStore(
        fileURL: SessionPlaces.support.appendingPathComponent("Appearance.json")
    )

    public let fileURL: URL
    public var themeSearchPaths: [String]?

    private(set) var document: AppearanceDocument
    private(set) var loadError: AppearanceStoreError?
    private var persistedData: Data?

    public init(fileURL: URL, themeSearchPaths: [String]? = nil) {
        self.fileURL = fileURL
        self.themeSearchPaths = themeSearchPaths
        self.document = AppearanceDocument()
        load()
    }

    /// Retrieve the stored override value for a key in a scope.
    public func value(for key: String, scope: AppearanceScope) -> String? {
        guard AppearanceKey(rawValue: key) != nil else { return nil }
        return document.overrides(for: scope)?[key]
    }

    /// Set or remove (when nil) an appearance override for a key in a scope.
    ///
    /// Validates inputs, persists atomically to disk before committing to memory,
    /// and broadcasts `Notification.Name.takoScopedAppearanceDidChange`.
    public func setValue(_ value: String?, for key: String, scope: AppearanceScope) throws {
        if let loadError {
            throw loadError
        }

        guard let appearanceKey = AppearanceKey(rawValue: key) else {
            throw AppearanceStoreError.invalidKey(key)
        }

        if let value {
            try AppearanceValidator.validate(value: value, for: appearanceKey)
        }
        try Self.validateIdentity(scope)

        var draft = document
        draft.setOverride(value, for: key, scope: scope)

        // Attempt persistence first; throws on failure
        try persist(draft)

        // Only published to memory and observers after persistence succeeds
        document = draft
        NotificationCenter.default.post(name: .takoScopedAppearanceDidChange, object: self)
    }

    /// Remove all appearance overrides for a scope.
    public func reset(_ scope: AppearanceScope) throws {
        if let loadError {
            throw loadError
        }

        var draft = document
        draft.reset(scope)

        // Attempt persistence first; throws on failure
        try persist(draft)

        // Only published to memory and observers after persistence succeeds
        document = draft
        NotificationCenter.default.post(name: .takoScopedAppearanceDidChange, object: self)
    }

    /// Choosing a full preset replaces custom fields at this level, while
    /// leaving other panes and workspaces untouched.
    func applyPreset(_ name: String, scope: AppearanceScope) throws {
        if let loadError { throw loadError }
        try AppearanceValidator.validate(value: name, for: .theme)
        try Self.validateIdentity(scope)
        var draft = document
        draft.reset(scope)
        draft.setOverride(name, for: "theme", scope: scope)
        try persist(draft)
        document = draft
        NotificationCenter.default.post(name: .takoScopedAppearanceDidChange, object: self)
    }

    /// Resolve the effective theme combining global theme, workspace overrides, and pane overrides.
    public func effectiveTheme(
        global: TerminalTheme,
        workspaceID: UUID?,
        paneID: UUID?
    ) -> TerminalTheme {
        effectiveTheme(global: global, workspaceID: workspaceID, sessionID: nil, paneID: paneID,
                       themeSearchPaths: themeSearchPaths)
    }

    /// Resolve the effective theme with explicit theme search paths.
    public func effectiveTheme(
        global: TerminalTheme,
        workspaceID: UUID?,
        paneID: UUID?,
        themeSearchPaths: [String]?
    ) -> TerminalTheme {
        effectiveTheme(global: global, workspaceID: workspaceID, sessionID: nil, paneID: paneID,
                       themeSearchPaths: themeSearchPaths)
    }

    /// Resolve global -> workspace -> session -> pane. `sessionID` is the
    /// native tab's stable identifier; nil skips the session layer.
    public func effectiveTheme(
        global: TerminalTheme,
        workspaceID: UUID?,
        sessionID: String?,
        paneID: UUID?,
        themeSearchPaths: [String]? = nil
    ) -> TerminalTheme {
        Self.resolve(document, global: global, workspaceID: workspaceID, sessionID: sessionID, paneID: paneID,
                     themeSearchPaths: themeSearchPaths ?? self.themeSearchPaths ?? TerminalTheme.themeSearchPaths)
    }

    /// Preview resetting one field without touching disk or notifying surfaces.
    func previewRemoving(_ key: String, scope: AppearanceScope, global: TerminalTheme,
                         workspaceID: UUID?, sessionID: String? = nil, paneID: UUID?) -> TerminalTheme {
        var draft = document
        draft.setOverride(nil, for: key, scope: scope)
        return Self.resolve(draft, global: global, workspaceID: workspaceID, sessionID: sessionID, paneID: paneID,
                            themeSearchPaths: themeSearchPaths ?? TerminalTheme.themeSearchPaths)
    }

    private static func resolve(_ doc: AppearanceDocument, global: TerminalTheme, workspaceID: UUID?,
                                sessionID: String?, paneID: UUID?, themeSearchPaths: [String]) -> TerminalTheme {
        ScopedAppearanceResolver.resolve(global: global,
            workspaceOverrides: workspaceID.flatMap { doc.overrides(for: .workspace($0)) },
            sessionOverrides: sessionID.flatMap { doc.overrides(for: .session($0)) },
            paneOverrides: paneID.flatMap { doc.overrides(for: .pane($0)) },
            themeSearchPaths: themeSearchPaths)
    }

    /// A session record must stay loadable: its identity is validated like
    /// a name so a corrupt key can never be persisted.
    static func validateIdentity(_ scope: AppearanceScope) throws {
        guard case .session(let id) = scope else { return }
        guard AppearanceValidator.isValidName(id) else {
            throw AppearanceStoreError.invalidValue(key: "session", value: id, reason: "Session identity must be non-empty and control-free")
        }
    }

    // MARK: - Persistence

    /// Commit a complete, validated transaction before publishing it. Move
    /// preservation and preset renames must not partially update split panes.
    func commitDocument(_ draft: AppearanceDocument) throws {
        if let loadError { throw loadError }
        guard draft.version == AppearanceDocument.currentVersion else {
            throw AppearanceStoreError.unsupportedVersion(draft.version, fileURL)
        }
        try draft.validateEntries(fileURL: fileURL)
        do { try persist(draft) }
        catch { throw AppearanceStoreError.persistenceFailed(error.localizedDescription) }
        document = draft
        NotificationCenter.default.post(name: .takoScopedAppearanceDidChange, object: self)
    }

    /// Destructive preset operations must not rely on a cached reference
    /// list after another process has edited appearance storage.
    func verifyDiskIsCurrent() throws {
        if let loadError { throw loadError }
        let current = FileManager.default.fileExists(atPath: fileURL.path) ? try Data(contentsOf: fileURL) : nil
        guard current == persistedData else {
            throw AppearanceStoreError.persistenceFailed("Appearance storage changed outside Tako; restart Tako to reload it. The external file was left untouched.")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Missing file is allowed; start clean
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            persistedData = data
            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.loadError = .corruptedFile(fileURL, "Root JSON value is not a dictionary")
                return
            }

            guard let version = jsonObject["version"] as? Int else {
                self.loadError = .corruptedFile(fileURL, "Missing or non-integer 'version' field")
                return
            }

            guard AppearanceDocument.supportedVersions.contains(version) else {
                self.loadError = .unsupportedVersion(version, fileURL)
                return
            }

            let decoder = JSONDecoder()
            let loaded = try decoder.decode(AppearanceDocument.self, from: data)
            try loaded.validateEntries(fileURL: fileURL)
            // A legacy file stays byte-identical on disk until the next
            // successful write, which then stores the migrated version.
            guard let migrated = AppearanceDocument.migrated(from: loaded) else {
                self.loadError = .unsupportedVersion(version, fileURL)
                return
            }
            self.document = migrated
        } catch let err as AppearanceStoreError {
            self.loadError = err
        } catch {
            self.loadError = .corruptedFile(fileURL, error.localizedDescription)
        }
    }

    private func persist(_ doc: AppearanceDocument) throws {
        try verifyDiskIsCurrent()
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: fileURL, options: .atomic)
        persistedData = data
    }
}
