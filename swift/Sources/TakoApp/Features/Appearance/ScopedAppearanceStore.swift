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

/// Main actor store for versioned scoped appearance overrides (workspace and pane).
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

    /// Resolve the effective theme combining global theme, workspace overrides, and pane overrides.
    public func effectiveTheme(
        global: TerminalTheme,
        workspaceID: UUID?,
        paneID: UUID?
    ) -> TerminalTheme {
        effectiveTheme(
            global: global,
            workspaceID: workspaceID,
            paneID: paneID,
            themeSearchPaths: themeSearchPaths
        )
    }

    /// Resolve the effective theme with explicit theme search paths.
    public func effectiveTheme(
        global: TerminalTheme,
        workspaceID: UUID?,
        paneID: UUID?,
        themeSearchPaths: [String]?
    ) -> TerminalTheme {
        let paths = themeSearchPaths ?? self.themeSearchPaths ?? TerminalTheme.themeSearchPaths
        let wsOverrides = workspaceID.flatMap { document.overrides(for: .workspace($0)) }
        let paneOverrides = paneID.flatMap { document.overrides(for: .pane($0)) }

        return ScopedAppearanceResolver.resolve(
            global: global,
            workspaceOverrides: wsOverrides,
            paneOverrides: paneOverrides,
            themeSearchPaths: paths
        )
    }

    /// Preview resetting one field without touching disk or notifying surfaces.
    func previewRemoving(_ key: String, scope: AppearanceScope, global: TerminalTheme,
                         workspaceID: UUID?, paneID: UUID?) -> TerminalTheme {
        var draft = document
        draft.setOverride(nil, for: key, scope: scope)
        return ScopedAppearanceResolver.resolve(global: global,
            workspaceOverrides: workspaceID.flatMap { draft.overrides(for: .workspace($0)) },
            paneOverrides: paneID.flatMap { draft.overrides(for: .pane($0)) },
            themeSearchPaths: themeSearchPaths ?? TerminalTheme.themeSearchPaths)
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Missing file is allowed; start clean
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.loadError = .corruptedFile(fileURL, "Root JSON value is not a dictionary")
                return
            }

            guard let version = jsonObject["version"] as? Int else {
                self.loadError = .corruptedFile(fileURL, "Missing or non-integer 'version' field")
                return
            }

            guard version == AppearanceDocument.currentVersion else {
                self.loadError = .unsupportedVersion(version, fileURL)
                return
            }

            let decoder = JSONDecoder()
            let loaded = try decoder.decode(AppearanceDocument.self, from: data)
            try loaded.validateEntries(fileURL: fileURL)
            self.document = loaded
        } catch let err as AppearanceStoreError {
            self.loadError = err
        } catch {
            self.loadError = .corruptedFile(fileURL, error.localizedDescription)
        }
    }

    private func persist(_ doc: AppearanceDocument) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: fileURL, options: .atomic)
    }
}
