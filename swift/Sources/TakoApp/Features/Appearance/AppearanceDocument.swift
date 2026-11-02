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
public struct AppearanceDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var workspaces: [String: [String: String]]
    public var panes: [String: [String: String]]

    public init(
        version: Int = AppearanceDocument.currentVersion,
        workspaces: [String: [String: String]] = [:],
        panes: [String: [String: String]] = [:]
    ) {
        self.version = version
        self.workspaces = workspaces
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey {
        case version, workspaces, panes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        let rawWorkspaces = try container.decodeIfPresent([String: [String: String]].self, forKey: .workspaces) ?? [:]
        let rawPanes = try container.decodeIfPresent([String: [String: String]].self, forKey: .panes) ?? [:]

        // Normalize UUID keys to uppercase for stable lookup
        workspaces = try Self.normalized(rawWorkspaces, decoder: decoder)
        panes = try Self.normalized(rawPanes, decoder: decoder)
    }

    private static func normalized(_ values: [String: [String: String]], decoder: Decoder) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for (key, fields) in values {
            let normalized = key.uppercased()
            guard result.updateValue(fields, forKey: normalized) == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Duplicate appearance identity: \(key)"))
            }
        }
        return result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(panes, forKey: .panes)
    }

    /// Retrieve stored overrides dictionary for a given scope.
    public func overrides(for scope: AppearanceScope) -> [String: String]? {
        switch scope {
        case .workspace(let id):
            return workspaces[id.uuidString.uppercased()]
        case .pane(let id):
            return panes[id.uuidString.uppercased()]
        }
    }

    /// Set an override value for a key in a scope, or remove it when value is nil.
    public mutating func setOverride(_ value: String?, for key: String, scope: AppearanceScope) {
        switch scope {
        case .workspace(let id):
            let idStr = id.uuidString.uppercased()
            var map = workspaces[idStr] ?? [:]
            if let value {
                map[key] = value
            } else {
                map.removeValue(forKey: key)
            }
            if map.isEmpty {
                workspaces.removeValue(forKey: idStr)
            } else {
                workspaces[idStr] = map
            }
        case .pane(let id):
            let idStr = id.uuidString.uppercased()
            var map = panes[idStr] ?? [:]
            if let value {
                map[key] = value
            } else {
                map.removeValue(forKey: key)
            }
            if map.isEmpty {
                panes.removeValue(forKey: idStr)
            } else {
                panes[idStr] = map
            }
        }
    }

    /// Remove all overrides associated with a scope.
    public mutating func reset(_ scope: AppearanceScope) {
        switch scope {
        case .workspace(let id):
            workspaces.removeValue(forKey: id.uuidString.uppercased())
        case .pane(let id):
            panes.removeValue(forKey: id.uuidString.uppercased())
        }
    }

    /// Validates all scopes, keys and values inside this document against schema rules.
    public func validateEntries(fileURL: URL) throws {
        for (idStr, fields) in workspaces {
            guard UUID(uuidString: idStr) != nil else {
                throw AppearanceStoreError.corruptedFile(fileURL, "Invalid UUID in workspaces: '\(idStr)'")
            }
            for (k, v) in fields {
                guard let appKey = AppearanceKey(rawValue: k) else {
                    throw AppearanceStoreError.corruptedFile(fileURL, "Unknown appearance key '\(k)' in workspace '\(idStr)'")
                }
                do {
                    try AppearanceValidator.validate(value: v, for: appKey)
                } catch {
                    throw AppearanceStoreError.corruptedFile(fileURL, "Invalid value for key '\(k)' in workspace '\(idStr)': \(error.localizedDescription)")
                }
            }
        }
        for (idStr, fields) in panes {
            guard UUID(uuidString: idStr) != nil else {
                throw AppearanceStoreError.corruptedFile(fileURL, "Invalid UUID in panes: '\(idStr)'")
            }
            for (k, v) in fields {
                guard let appKey = AppearanceKey(rawValue: k) else {
                    throw AppearanceStoreError.corruptedFile(fileURL, "Unknown appearance key '\(k)' in pane '\(idStr)'")
                }
                do {
                    try AppearanceValidator.validate(value: v, for: appKey)
                } catch {
                    throw AppearanceStoreError.corruptedFile(fileURL, "Invalid value for key '\(k)' in pane '\(idStr)': \(error.localizedDescription)")
                }
            }
        }
    }
}
