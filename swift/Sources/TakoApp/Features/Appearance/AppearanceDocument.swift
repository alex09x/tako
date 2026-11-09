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

/// Versioned persistent representation of scoped appearance overrides.
///
/// Version 1 stored workspaces and panes. Version 2 adds sessions. A v1 file
/// is migrated explicitly in memory (`migrated(from:)`) and rewritten as v2
/// only by the next successful atomic write; any other version fails closed.
public struct AppearanceDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let legacyVersions: Set<Int> = [1]
    public static var supportedVersions: Set<Int> { legacyVersions.union([currentVersion]) }

    public var version: Int
    public var workspaces: [String: [String: String]]
    public var sessions: [String: [String: String]]
    public var panes: [String: [String: String]]

    public init(
        version: Int = AppearanceDocument.currentVersion,
        workspaces: [String: [String: String]] = [:],
        sessions: [String: [String: String]] = [:],
        panes: [String: [String: String]] = [:]
    ) {
        self.version = version
        self.workspaces = workspaces
        self.sessions = sessions
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspaces, sessions, panes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        if Self.legacyVersions.contains(version), container.contains(.sessions) {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Version \(version) documents cannot contain sessions"))
        }
        let rawWorkspaces = try container.decodeIfPresent([String: [String: String]].self, forKey: .workspaces) ?? [:]
        let rawSessions = try container.decodeIfPresent([String: [String: String]].self, forKey: .sessions) ?? [:]
        let rawPanes = try container.decodeIfPresent([String: [String: String]].self, forKey: .panes) ?? [:]

        // Normalize identity keys for stable lookup
        workspaces = try Self.normalized(rawWorkspaces, decoder: decoder) { $0.uppercased() }
        sessions = try Self.normalized(rawSessions, decoder: decoder, AppearanceScope.sessionKey)
        panes = try Self.normalized(rawPanes, decoder: decoder) { $0.uppercased() }
    }

    /// Explicit backwards-compatible upgrade. A v1 document has no session
    /// records, so its workspace and pane styles resolve exactly as before.
    public static func migrated(from document: AppearanceDocument) -> AppearanceDocument? {
        if document.version == currentVersion { return document }
        guard legacyVersions.contains(document.version) else { return nil }
        var upgraded = document
        upgraded.version = currentVersion
        return upgraded
    }

    private static func normalized(_ values: [String: [String: String]], decoder: Decoder,
                                   _ key: (String) -> String) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (raw, fields) in values {
            guard result.updateValue(fields, forKey: key(raw)) == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Duplicate appearance identity: \(raw)"))
            }
        }
        return result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(workspaces, forKey: .workspaces)
        if !Self.legacyVersions.contains(version) { try container.encode(sessions, forKey: .sessions) }
        try container.encode(panes, forKey: .panes)
    }

    private func table(_ scope: AppearanceScope) -> (WritableKeyPath<AppearanceDocument, [String: [String: String]]>, String) {
        switch scope {
        case .workspace(let id): return (\.workspaces, id.uuidString.uppercased())
        case .session(let id): return (\.sessions, AppearanceScope.sessionKey(id))
        case .pane(let id): return (\.panes, id.uuidString.uppercased())
        }
    }

    /// Retrieve stored overrides dictionary for a given scope.
    public func overrides(for scope: AppearanceScope) -> [String: String]? {
        let (path, key) = table(scope)
        return self[keyPath: path][key]
    }

    /// Set an override value for a key in a scope, or remove it when value is nil.
    public mutating func setOverride(_ value: String?, for key: String, scope: AppearanceScope) {
        let (path, id) = table(scope)
        var map = self[keyPath: path][id] ?? [:]
        if let value { map[key] = value } else { map.removeValue(forKey: key) }
        self[keyPath: path][id] = map.isEmpty ? nil : map
    }

    /// Remove all overrides associated with a scope.
    public mutating func reset(_ scope: AppearanceScope) {
        let (path, id) = table(scope)
        self[keyPath: path].removeValue(forKey: id)
    }

    /// Validates all scopes, keys and values inside this document against schema rules.
    public func validateEntries(fileURL: URL) throws {
        try Self.validate(workspaces, kind: "workspace", fileURL: fileURL) { UUID(uuidString: $0) != nil }
        try Self.validate(sessions, kind: "session", fileURL: fileURL, AppearanceValidator.isValidName)
        try Self.validate(panes, kind: "pane", fileURL: fileURL) { UUID(uuidString: $0) != nil }
    }

    private static func validate(_ table: [String: [String: String]], kind: String, fileURL: URL,
                                 _ validIdentity: (String) -> Bool) throws {
        for (idStr, fields) in table {
            guard validIdentity(idStr) else {
                throw AppearanceStoreError.corruptedFile(fileURL, "Invalid identity in \(kind)s: '\(idStr)'")
            }
            for (k, v) in fields {
                guard let appKey = AppearanceKey(rawValue: k) else {
                    throw AppearanceStoreError.corruptedFile(fileURL, "Unknown appearance key '\(k)' in \(kind) '\(idStr)'")
                }
                do {
                    try AppearanceValidator.validate(value: v, for: appKey)
                } catch {
                    throw AppearanceStoreError.corruptedFile(fileURL, "Invalid value for key '\(k)' in \(kind) '\(idStr)': \(error.localizedDescription)")
                }
            }
        }
    }
}
